// Package version 提供 server 版本号。编译时经 -ldflags "-X ..." 注入,
// 本地 go run / 未注入时 fallback 到 Version(开发默认)。
package version

// Version 编译时注入(如 1.6.1)。
// 注入方式:go build -ldflags "-X github.com/wanling/server/internal/version.Version=1.6.1"
var Version = "1.6.4"

// BuildCommit 编译时注入的 git commit(短 hash),便于定位部署版本。
// 未注入时为空串。
var BuildCommit = ""
