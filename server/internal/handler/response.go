package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

// CodeInternalError 5xx 默认错误 code
const CodeInternalError = "internal_error"

// Ok 写入成功响应（HTTP 200）。data 字段为 payload；payload 为 nil 时 data 写 null。
func Ok(c *gin.Context, payload any) {
	c.JSON(http.StatusOK, gin.H{"ok": true, "data": payload})
}

// OkCreated 同 Ok 但用 201 Created 状态码
func OkCreated(c *gin.Context, payload any) {
	c.JSON(http.StatusCreated, gin.H{"ok": true, "data": payload})
}

// Err 写入失败响应：{ok: false, error: {code, message, ...extra}}
// extra 用于追加业务字段（如 approval conflict 的 state）
func Err(c *gin.Context, status int, code, message string, extra ...gin.H) {
	errBody := gin.H{"code": code, "message": message}
	for _, e := range extra {
		for k, v := range e {
			errBody[k] = v
		}
	}
	c.JSON(status, gin.H{"ok": false, "error": errBody})
}

// ErrMsg 写入失败响应，code 固定 CodeInternalError（用于无具体业务 code 的 5xx）
func ErrMsg(c *gin.Context, status int, message string) {
	Err(c, status, CodeInternalError, message)
}

// ErrCode 写入带业务 code 的失败响应（与 Err 等价，命名直观点）
func ErrCode(c *gin.Context, status int, code, message string) {
	Err(c, status, code, message)
}
