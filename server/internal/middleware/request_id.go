// Package middleware 提供全局 HTTP 中间件。
package middleware

import (
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/wanling/server/internal/log"
)

// RequestID 给每个请求注入 request_id:
//   - 优先用客户端传的 X-Request-ID 头(链路追踪场景)
//   - 否则生成 UUID v4
//   - 写入 c.Set("requestID", id) + 响应头 X-Request-ID + ctx(供 log.FromCtx 用)
func RequestID() gin.HandlerFunc {
	return func(c *gin.Context) {
		rid := c.GetHeader("X-Request-ID")
		if rid == "" {
			rid = uuid.NewString()
		}
		c.Set("requestID", rid)
		c.Header("X-Request-ID", rid)
		ctx := log.WithRequestID(c.Request.Context(), rid)
		c.Request = c.Request.WithContext(ctx)
		c.Next()
	}
}
