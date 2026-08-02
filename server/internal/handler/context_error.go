package handler

import (
	"context"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
)

// IsContextError 判断 err 是否由 ctx 超时/cancel 引起。
//
// 用法:handler 内调 repo 后,如返错,先判断是否 ctx 错误:
//
//	if err != nil {
//	    if IsContextError(err) {
//	        // client 断开或超时,TimeoutMiddleware 已写 504,这里直接 return
//	        return
//	    }
//	    ErrMsg(c, http.StatusInternalServerError, "...")
//	    return
//	}
//
// 设计要点:
//   - 大多数 handler 不需显式调用本函数 — TimeoutMiddleware 已在 middleware 层处理超时
//   - 仅在 handler 内部捕获到 ctx 错误后想区分响应时使用
//   - 与 H7(脱敏 500 错误)兼容:ctx 错误不泄漏 SQL/表名等内部信息
func IsContextError(err error) bool {
	return errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled)
}

// RespondContextError 在 handler 内检测到 ctx 错误时统一响应。
// 超时 → 504,client 断开 → 499(Nginx 约定)。
//
// 已写响应时不重复写(防止 TimeoutMiddleware 已写过的情况)。
func RespondContextError(c *gin.Context, err error) bool {
	if !IsContextError(err) {
		return false
	}
	if c.Writer.Written() {
		return true
	}
	if errors.Is(err, context.DeadlineExceeded) {
		// 超时走 envelope,code=timeout 与 504 状态对齐
		Err(c, http.StatusGatewayTimeout, "timeout", "请求超时")
		c.Abort()
		return true
	}
	// context.Canceled — client 断开,499 是 Nginx 约定(non-standard)
	// 499 无 body,沿用 c.AbortWithStatus(不 envelope)
	c.AbortWithStatus(499)
	return true
}
