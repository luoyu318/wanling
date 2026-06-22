// wanling-admin — 用户管理 CLI 工具。
//
// 用法：
//   wanling-admin add-user --username=<name> [--password=<pwd>]
//   wanling-admin reset-password --username=<name> [--new-password=<pwd>]
//   wanling-admin list-users
//
// --password 不传时从终端读取（无回显，golang.org/x/term）。
// 复用主程序的 config 加载（DB 连接从 .env / 环境变量拿）。
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/wanling/server/internal/config"
	"github.com/wanling/server/internal/repository"
	"github.com/joho/godotenv"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/term"
)

const usage = `wanling-admin — Wanling 用户管理 CLI

用法:
  wanling-admin <command> [flags]

命令:
  add-user           创建用户（注册接口已关，这是唯一加用户途径）
  reset-password     重置用户密码
  list-users         列出所有用户

示例:
  wanling-admin add-user --username=alice
  wanling-admin add-user --username=bob --password=secret123
  wanling-admin reset-password --username=alice
  wanling-admin list-users

配置:
  从同目录 .env 文件读 DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME 等。
  与 server 共用一份 .env，无需另配。
`

func main() {
	_ = godotenv.Load() // 静默：不存在则依赖环境变量

	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(1)
	}

	switch os.Args[1] {
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	case "add-user":
		addUserCmd(os.Args[2:])
	case "reset-password":
		resetPasswordCmd(os.Args[2:])
	case "list-users":
		listUsersCmd()
	default:
		fmt.Fprintf(os.Stderr, "未知命令: %s\n\n%s", os.Args[1], usage)
		os.Exit(1)
	}
}

// mustOpenDB 加载 config + 打开 DB 连接。失败直接 fatal。
func mustOpenDB() *repository.UserRepo {
	cfg, err := config.Load()
	if err != nil {
		fatal("config 加载失败: %v", err)
	}
	db, err := repository.NewDB(cfg.DB)
	if err != nil {
		fatal("DB 连接失败: %v", err)
	}
	return repository.NewUserRepo(db)
}

func addUserCmd(args []string) {
	fs := flag.NewFlagSet("add-user", flag.ExitOnError)
	username := fs.String("username", "", "用户名（必填，3-64 字符）")
	password := fs.String("password", "", "密码（不传则终端交互输入，≥6 位）")
	_ = fs.Parse(args)

	if *username == "" {
		fatal("--username 必填")
	}
	if len(*username) < 3 || len(*username) > 64 {
		fatal("--username 长度需在 3-64 之间")
	}

	pwd := *password
	if pwd == "" {
		pwd = readPasswordFromTerminal("密码 (≥6 位): ")
	}
	if len(pwd) < 6 {
		fatal("密码至少 6 位")
	}

	repo := mustOpenDB()

	// 重名检查
	existing, err := repo.GetByUsername(*username)
	if err != nil {
		fatal("查询失败: %v", err)
	}
	if existing != nil {
		fatal("用户名已存在: %s", *username)
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(pwd), bcrypt.DefaultCost)
	if err != nil {
		fatal("密码哈希失败: %v", err)
	}

	user, err := repo.Create(*username, string(hash))
	if err != nil {
		fatal("创建失败: %v", err)
	}

	fmt.Printf("✓ 用户创建成功\n  id:        %s\n  username:  %s\n  created:   %s\n",
		user.ID, user.Username, user.CreatedAt.Format(time.RFC3339))
}

func resetPasswordCmd(args []string) {
	fs := flag.NewFlagSet("reset-password", flag.ExitOnError)
	username := fs.String("username", "", "用户名（必填）")
	password := fs.String("new-password", "", "新密码（不传则终端交互输入）")
	_ = fs.Parse(args)

	if *username == "" {
		fatal("--username 必填")
	}

	pwd := *password
	if pwd == "" {
		pwd = readPasswordFromTerminal("新密码 (≥6 位): ")
	}
	if len(pwd) < 6 {
		fatal("密码至少 6 位")
	}

	repo := mustOpenDB()

	user, err := repo.GetByUsername(*username)
	if err != nil {
		fatal("查询失败: %v", err)
	}
	if user == nil {
		fatal("用户不存在: %s", *username)
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(pwd), bcrypt.DefaultCost)
	if err != nil {
		fatal("密码哈希失败: %v", err)
	}

	if err := repo.UpdatePassword(user.ID, string(hash)); err != nil {
		fatal("更新失败: %v", err)
	}

	fmt.Printf("✓ 密码已重置\n  username:  %s\n  id:        %s\n", user.Username, user.ID)
}

func listUsersCmd() {
	repo := mustOpenDB()
	users, err := repo.List()
	if err != nil {
		fatal("查询失败: %v", err)
	}
	if len(users) == 0 {
		fmt.Println("(无用户)")
		return
	}

	// 表格式输出，宽度按最长用户名对齐
	maxLen := len("username")
	for _, u := range users {
		if len(u.Username) > maxLen {
			maxLen = len(u.Username)
		}
	}
	hdr := fmt.Sprintf("%-36s  %-*s  %s", "id", maxLen, "username", "created_at")
	fmt.Println(hdr)
	fmt.Println(strings.Repeat("-", len(hdr)))
	for _, u := range users {
		fmt.Printf("%-36s  %-*s  %s\n",
			u.ID, maxLen, u.Username, u.CreatedAt.Format(time.RFC3339))
	}
	fmt.Printf("\n共 %d 个用户\n", len(users))
}

// readPasswordFromTerminal 从 /dev/tty 读密码（无回显）。
// 输入完成后打印一个换行避免后续输出贴在同一行。
func readPasswordFromTerminal(prompt string) string {
	fmt.Fprint(os.Stderr, prompt)
	bytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr) // 换行
	if err != nil {
		fatal("读取密码失败: %v", err)
	}
	return string(bytes)
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "✗ "+format+"\n", args...)
	os.Exit(1)
}
