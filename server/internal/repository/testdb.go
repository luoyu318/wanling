package repository

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	_ "github.com/lib/pq"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// 进程级共享 PG 容器。所有测试包复用同一个容器实例，
// 每个测试函数在自己的独立 database 中运行（CREATE DATABASE + migration），
// 测试结束 DROP DATABASE。容器只启动一次（~5s），单测试开销降到 ~200ms。
var (
	sharedContainerOnce sync.Once
	sharedHost          string
	sharedPort          string
	containerInitErr    error
)

// startSharedContainer 启动进程级共享 PG 容器（仅一次）。
func startSharedContainer() error {
	sharedContainerOnce.Do(func() {
		ctx := context.Background()
		req := testcontainers.ContainerRequest{
			Image:        "postgres:16-alpine",
			ExposedPorts: []string{"5432/tcp"},
			Env:          map[string]string{"POSTGRES_USER": "test", "POSTGRES_PASSWORD": "test", "POSTGRES_DB": "test"},
			WaitingFor:   wait.ForLog("database system is ready to accept connections").WithOccurrence(2),
		}
		pgC, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
			ContainerRequest: req, Started: true,
		})
		if err != nil {
			containerInitErr = fmt.Errorf("启动共享 PG 容器失败: %w", err)
			return
		}
		sharedHost, err = pgC.Host(ctx)
		if err != nil {
			containerInitErr = fmt.Errorf("获取容器 host 失败: %w", err)
			return
		}
		port, err := pgC.MappedPort(ctx, "5432/tcp")
		if err != nil {
			containerInitErr = fmt.Errorf("获取容器 port 失败: %w", err)
			return
		}
		sharedPort = port.Port()
	})
	return containerInitErr
}

// SetupTestDB 起一个独立 database（在共享 PG 容器内），跑 migrations/001_init.sql，返回 *sql.DB。
// 跳过条件:CI=1 时跳过(在 CI 上跑 docker 太重);本地默认启用。
//
// 共享容器设计:进程级 sync.Once 启动一个 PG 容器,所有测试函数复用。
// 每个测试在容器内 CREATE DATABASE <uuid> 创建独立库,跑 migration,
// 测试结束 t.Cleanup DROP DATABASE。避免每个测试起独立容器(~5s/次)的开销。
//
// 单 init 文件设计:历史 21 个 migration 已合并到 001_init.sql,
// 不再需要 migrationSkipPrefixes / SetupTestDBSkipping015 等过渡期 helper。
func SetupTestDB(t *testing.T) *sql.DB {
	t.Helper()
	if os.Getenv("CI") == "1" {
		t.Skip("CI 环境跳过 testcontainers 测试")
	}

	if err := startSharedContainer(); err != nil {
		t.Fatalf("%v", err)
	}

	// 连到 maintenance DB（test 库）创建独立测试库
	mgmtDSN := fmt.Sprintf("host=%s port=%s user=test password=test dbname=test sslmode=disable", sharedHost, sharedPort)
	mgmtDB, err := sql.Open("postgres", mgmtDSN)
	if err != nil {
		t.Fatalf("打开 maintenance DB 失败: %v", err)
	}
	defer mgmtDB.Close()

	// 等 PG ready（容器启动后首次连接可能还没就绪）
	for i := 0; i < 30; i++ {
		if err := mgmtDB.Ping(); err == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if err := mgmtDB.Ping(); err != nil {
		t.Fatalf("maintenance DB ping 失败: %v", err)
	}

	// 创建独立测试库（UUID 后缀避免冲突，前缀保留可读性便于排查）
	dbName := "t_" + sanitizeDBName(t.Name()) + "_" + uuid.New().String()[:8]
	// PG 库名最长 63 字符，截断保留 UUID 后缀
	if len(dbName) > 63 {
		// 保留最后 9 字符（_uuid8），前面截断
		dbName = dbName[:54] + dbName[len(dbName)-9:]
	}
	_, err = mgmtDB.ExecContext(t.Context(), fmt.Sprintf(`CREATE DATABASE %q`, dbName))
	if err != nil {
		t.Fatalf("CREATE DATABASE 失败: %v", err)
	}

	// 测试结束 DROP DATABASE（连到 maintenance DB 执行）
	t.Cleanup(func() {
		// 先连 maintenance DB（此时测试 DB 的连接需已关闭）
		killDB, err := sql.Open("postgres", mgmtDSN)
		if err != nil {
			t.Logf("警告:打开 maintenance DB 失败,跳过 DROP: %v", err)
			return
		}
		defer killDB.Close()
		// 断开测试库的活跃连接，否则 DROP DATABASE 会因连接占用失败
		if _, err := killDB.ExecContext(context.Background(),
			fmt.Sprintf(`SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '%s' AND pid != pg_backend_pid()`, dbName)); err != nil {
			t.Logf("警告:terminate backend 失败: %v", err)
		}
		if _, err := killDB.ExecContext(context.Background(),
			fmt.Sprintf(`DROP DATABASE IF EXISTS %q`, dbName)); err != nil {
			t.Logf("警告:DROP DATABASE 失败: %v", err)
		}
	})

	// 连到独立测试库
	dsn := fmt.Sprintf("host=%s port=%s user=test password=test dbname=%s sslmode=disable", sharedHost, sharedPort, dbName)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("打开测试 DB 失败: %v", err)
	}

	// 跑 migrations 目录下所有 .sql(当前仅 001_init.sql,合并已完成)
	migrations, err := filepath.Glob(filepath.Join("..", "..", "migrations", "*.sql"))
	if err != nil {
		t.Fatalf("glob migrations 失败: %v", err)
	}
	for _, m := range migrations {
		sql, err := os.ReadFile(m) // #nosec G304 -- 测试辅助读本地 SQL
		if err != nil {
			t.Fatalf("读 migration 失败 %s: %v", m, err)
		}
		if _, err := db.Exec(string(sql)); err != nil {
			t.Fatalf("执行 migration 失败 %s: %v", m, err)
		}
	}

	return db
}

// sanitizeDBName 把测试名转成合法 PG 库名：只保留小写字母/数字/下划线，截断到 60 字符。
func sanitizeDBName(name string) string {
	out := make([]byte, 0, len(name))
	for _, c := range name {
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_':
			out = append(out, byte(c)) // #nosec G115 -- 测试辅助，DB 名只含 ASCII
		case c >= 'A' && c <= 'Z':
			out = append(out, byte(c+32)) // 转小写
		default:
			out = append(out, '_')
		}
	}
	// 确保不以数字开头（PG 库名不能以数字开头）
	if len(out) > 0 && out[0] >= '0' && out[0] <= '9' {
		out = append([]byte{'t'}, out...)
	}
	if len(out) > 60 {
		out = out[:60]
	}
	if len(out) == 0 {
		out = []byte("t_default")
	}
	return string(out)
}
