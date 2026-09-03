// Package middleware 提供全局 HTTP 中间件。
package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
)

// JSONBodyLimit 全局 JSON 请求体限制(防超大 JSON 请求体耗内存)。
//   - multipart 上传路由(如 /api/upload、/api/mini-programs)按 Content-Type 跳过,
//     由各 handler 自带的 MaxBytesReader 按各自上限精准拦截
//   - /ws 读取二进制帧,也跳过(由 ws_handler.SetReadLimit 64KB 兜底)
func JSONBodyLimit(maxBytes int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		isMultipart := strings.HasPrefix(c.Request.Header.Get("Content-Type"), "multipart/form-data")
		if isMultipart || c.Request.URL.Path == "/api/upload" || c.Request.URL.Path == "/ws" {
			c.Next()
			return
		}
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, maxBytes)
		c.Next()
	}
}
