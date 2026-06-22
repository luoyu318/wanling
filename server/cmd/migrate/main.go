package main

import (
	"bufio"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "github.com/lib/pq"
)

func main() {
	// 解析参数
	dryRun := false
	statusOnly := false
	markApplied := false
	envFile := ".env"
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--dry-run":
			dryRun = true
		case "--status":
			statusOnly = true
		case "--mark-applied":
			markApplied = true
		}
		if strings.HasPrefix(arg, "--env=") {
			envFile = strings.TrimPrefix(arg, "--env=")
		}
	}

	// 读 .env
	dsn := loadDSN(envFile)
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "错误: 无法从", envFile, "读取数据库连接")
		os.Exit(1)
	}

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		fmt.Fprintln(os.Stderr, "连接数据库失败:", err)
		os.Exit(1)
	}
	defer db.Close()

	if err := db.Ping(); err != nil {
		fmt.Fprintln(os.Stderr, "数据库无法连通:", err)
		os.Exit(1)
	}

	// 创建 schema_migrations 表(幂等)
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		version VARCHAR(255) PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`); err != nil {
		fmt.Fprintln(os.Stderr, "创建 schema_migrations 表失败:", err)
		os.Exit(1)
	}

	if statusOnly {
		showStatus(db)
		return
	}

	// 读 migrations 目录
	// findProjectRoot 返回 go.mod 所在目录（即 server/），migrations 是它的直接子目录
	projectRoot := findProjectRoot()
	migrationsDir := filepath.Join(projectRoot, "migrations")
	entries, err := os.ReadDir(migrationsDir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "读取 migrations 目录失败:", err)
		os.Exit(1)
	}

	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	// 查已应用的版本
	applied := make(map[string]bool)
	rows, err := db.Query(`SELECT version FROM schema_migrations ORDER BY version`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var v string
			rows.Scan(&v)
			applied[v] = true
		}
	}

	// --mark-applied: 把 migrations 目录里所有未登记的版本写入 schema_migrations
	// 用于老库接新工具的 baseline 场景（表已存在但工具是新引入的）
	if markApplied {
		markMigrationsApplied(db, files, applied)
		return
	}

	if dryRun {
		fmt.Println("═══ 模拟运行(不写入数据库) ═══")
	}
	fmt.Println()

	for _, f := range files {
		version := strings.TrimSuffix(f, ".sql")
		if applied[version] {
			fmt.Printf("  ✓ %s (已应用)\n", f)
			continue
		}

		sqlContent, err := os.ReadFile(filepath.Join(migrationsDir, f))
		if err != nil {
			fmt.Fprintln(os.Stderr, "读取", f, "失败:", err)
			os.Exit(1)
		}

		if dryRun {
			fmt.Printf("  → %s (待应用, %d 字符)\n", f, len(sqlContent))
			fmt.Println(string(sqlContent))
			continue
		}

		// 在一个事务内执行 migration + 记录
		tx, err := db.Begin()
		if err != nil {
			fmt.Fprintln(os.Stderr, "启动事务失败:", err)
			os.Exit(1)
		}

		// 执行 SQL
		if _, err := tx.Exec(string(sqlContent)); err != nil {
			tx.Rollback()
			fmt.Fprintf(os.Stderr, "  ✗ %s 执行失败: %v\n", f, err)
			os.Exit(1)
		}

		// 记录版本
		if _, err := tx.Exec(
			`INSERT INTO schema_migrations (version, applied_at) VALUES ($1, $2)`,
			version, time.Now(),
		); err != nil {
			tx.Rollback()
			fmt.Fprintf(os.Stderr, "  ✗ %s 记录版本失败: %v\n", f, err)
			os.Exit(1)
		}

		if err := tx.Commit(); err != nil {
			fmt.Fprintln(os.Stderr, "提交事务失败:", err)
			os.Exit(1)
		}

		fmt.Printf("  ✓ %s 已应用\n", f)
	}

	fmt.Println()
	if dryRun {
		fmt.Println("模拟运行结束。去掉 --dry-run 执行真实迁移。")
	} else {
		fmt.Println("所有迁移执行完毕。")
	}
}

func markMigrationsApplied(db *sql.DB, files []string, applied map[string]bool) {
	fmt.Println("═══ 标记已应用 ═══")
	fmt.Println()
	any := false
	for _, f := range files {
		version := strings.TrimSuffix(f, ".sql")
		if applied[version] {
			continue
		}
		if _, err := db.Exec(
			`INSERT INTO schema_migrations (version, applied_at) VALUES ($1, $2)`,
			version, time.Now(),
		); err != nil {
			fmt.Fprintf(os.Stderr, "  ✗ %s 标记失败: %v\n", f, err)
			os.Exit(1)
		}
		fmt.Printf("  + %s 已标记为已应用\n", f)
		any = true
	}
	if !any {
		fmt.Println("  (无需标记，migrations 目录里的版本都已在 schema_migrations 中)")
	}
	fmt.Println()
	showStatus(db)
}

func showStatus(db *sql.DB) {
	fmt.Println("═══ 迁移状态 ═══")
	fmt.Println()
	rows, err := db.Query(`SELECT version, applied_at FROM schema_migrations ORDER BY version`)
	if err != nil {
		fmt.Fprintln(os.Stderr, "查询迁移状态失败:", err)
		os.Exit(1)
	}
	defer rows.Close()

	hasAny := false
	for rows.Next() {
		hasAny = true
		var v string
		var at time.Time
		rows.Scan(&v, &at)
		fmt.Printf("  ✓ %s  (%s)\n", v, at.Local().Format("2006-01-02 15:04:05"))
	}
	if !hasAny {
		fmt.Println("  (尚无迁移记录)")
	}
}

func loadDSN(envFile string) string {
	f, err := os.Open(envFile)
	if err != nil {
		return ""
	}
	defer f.Close()

	env := make(map[string]string)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			env[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
		}
	}

	host := env["DB_HOST"]
	port := env["DB_PORT"]
	user := env["DB_USER"]
	pass := env["DB_PASSWORD"]
	name := env["DB_NAME"]
	sslmode := env["DB_SSLMODE"]
	if sslmode == "" {
		sslmode = "disable"
	}
	if host == "" || user == "" || name == "" {
		return ""
	}
	return fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=%s",
		host, port, user, pass, name, sslmode)
}

func findProjectRoot() string {
	// 从当前目录向上找 .git 或 go.mod
	wd, _ := os.Getwd()
	dir := wd
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return wd
		}
		dir = parent
	}
}
