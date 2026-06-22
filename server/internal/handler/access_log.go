package handler

import (
	"fmt"
	"time"

	"github.com/gin-gonic/gin"
)

// BusinessAccessLog 仅记录命中已注册路由的请求，扫描器探测的 NoRoute 404 完全静默。
//
// 背景：gin.Default() 自带的 Logger 会对每个请求（含 NoRoute）打 access log，
// 导致公网扫描器（nmap / Actuator / /mcp / /HNAP1 等）的探测请求污染 journalctl。
// 本中间件在 c.Next() 之后用 c.FullPath() 判定：
//   - 命中注册路由（如 /api/conversations/:id）→ 返回路由模板，记一行日志
//   - 命中 NoRoute（扫描器访问不存在的路径）→ 返回 ""，静默 return
//
// FullPath 是路由引擎给的判定，零误判、无需维护路径白名单。
// 输出格式与 gin 默认 Logger 一致（无 ANSI 颜色，适配 systemd journald）：
//
//	[GIN] 2026/06/19 - 02:52:44 | 200 | 2.78ms | 203.0.113.42 | GET "/api/users/me"
func BusinessAccessLog() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()

		c.Next()

		// 命中 NoRoute 的请求 FullPath 返回空串，直接静默。
		// 这会过滤掉扫描器对 /mcp /actuator/health /HNAP1 等不存在路径的探测。
		if c.FullPath() == "" {
			return
		}

		path := c.Request.URL.Path
		raw := c.Request.URL.RawQuery
		if raw != "" {
			path = path + "?" + raw
		}

		fmt.Fprintf(gin.DefaultErrorWriter, "[GIN] %v | %3d | %13v | %15s | %-7s %#v\n",
			start.Format("2006/01/02 - 15:04:05"),
			c.Writer.Status(),
			time.Since(start),
			c.ClientIP(),
			c.Request.Method,
			path,
		)
	}
}
