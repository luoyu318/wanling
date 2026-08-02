package handler

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

// TimeoutMiddleware 给 /api/* 请求加统一超时，超时返 504 Gateway Timeout。
//
// 纯 context timeout 方案（无 goroutine，零 race）：
//   - c.Next() 同步调用，repo 层消费 ctx（queryExecutor Context 变体）
//   - ctx 超时 → DB 查询返回错误 → handler 走 error path 返回
//   - c.Next() 返回后，检测 DeadlineExceeded + !Written → 写 504
//
// 仅对 /api/* 生效，/ws（长连接）和 /health（快速）跳过。
func TimeoutMiddleware(timeout time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		if !strings.HasPrefix(c.Request.URL.Path, "/api/") {
			c.Next()
			return
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), timeout)
		defer cancel()
		c.Request = c.Request.WithContext(ctx)

		c.Next()

		if ctx.Err() == context.DeadlineExceeded && !c.Writer.Written() {
			Err(c, http.StatusGatewayTimeout, "timeout", "请求超时")
		}
	}
}
