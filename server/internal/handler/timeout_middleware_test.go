package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

// TestTimeoutMiddleware_SlowHandler 验证消费 ctx 的慢 handler 超时后返 504。
//
// 纯 context timeout 方案下，c.Next() 同步阻塞等 handler 返回。
// handler 通过 <-c.Request.Context().Done() 感知超时后退出，
// c.Next() 返回后中间件检测 DeadlineExceeded 写 504。
func TestTimeoutMiddleware_SlowHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(TimeoutMiddleware(50 * time.Millisecond))
	r.GET("/api/slow", func(c *gin.Context) {
		// 模拟真实 handler：等 ctx 超时后退出（DB 查询 ctx cancel 后立即返回错误）
		<-c.Request.Context().Done()
		// handler 发现 ctx 取消，走 error path 但还没写响应
		// 这里不写响应，让中间件兜底写 504
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/slow", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusGatewayTimeout {
		t.Errorf("期望 504, 实际 %d", w.Code)
	}
}

// TestTimeoutMiddleware_FastHandler 验证快 handler 正常通过
func TestTimeoutMiddleware_FastHandler(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(TimeoutMiddleware(50 * time.Millisecond))
	r.GET("/api/fast", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/fast", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("期望 200, 实际 %d", w.Code)
	}
}

// TestTimeoutMiddleware_NonApiPath 验证 /ws 等非 /api/* 路径不挂超时。
//
// /ws 路径中间件提前 return（不包装 timeout ctx），所以即便 handler 耗时
// 超过配置的 timeout 阈值，也不会被写 504。用 time.Sleep 模拟慢 handler
// （/ws 不被中间件包装，无需 ctx 中断，sleep 即可）。
func TestTimeoutMiddleware_NonApiPath(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(TimeoutMiddleware(50 * time.Millisecond))
	r.GET("/ws", func(c *gin.Context) {
		time.Sleep(100 * time.Millisecond) // 超过超时阈值，但 /ws 不挂超时
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/ws", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("期望 200(/ws 不挂超时), 实际 %d", w.Code)
	}
}

// TestTimeoutMiddleware_HandlerAlreadyWrote 验证 handler 已写响应时中间件不重复写 504。
// 场景：handler 超时但走自己的 error path 写了响应。
func TestTimeoutMiddleware_HandlerAlreadyWrote(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(TimeoutMiddleware(50 * time.Millisecond))
	r.GET("/api/slow-write", func(c *gin.Context) {
		<-c.Request.Context().Done() // 等 ctx 超时
		// handler 自己写了响应（非 504）
		c.JSON(http.StatusServiceUnavailable, gin.H{"err": "timeout in handler"})
	})

	w := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/api/slow-write", nil)
	r.ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("期望 503（handler 自己写的）, 实际 %d", w.Code)
	}
}
