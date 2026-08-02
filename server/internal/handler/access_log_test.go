package handler

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// captureOutput 把 gin.DefaultErrorWriter 临时换成 buffer，
// 返回的 reset 函数在测试结束前 defer 调用，恢复原 writer。
// gin 默认把 access log 写到 DefaultErrorWriter（os.Stderr），便于 systemd 采集。
func captureOutput() (*bytes.Buffer, func()) {
	buf := &bytes.Buffer{}
	old := gin.DefaultErrorWriter
	gin.DefaultErrorWriter = buf
	return buf, func() { gin.DefaultErrorWriter = old }
}

// TestBusinessAccessLog_LogsRegisteredRoute 验证命中注册路由的请求会被记录。
// 用 GET /health（公开路由）做样本，不依赖任何业务 handler。
func TestBusinessAccessLog_LogsRegisteredRoute(t *testing.T) {
	buf, reset := captureOutput()
	defer reset()

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(BusinessAccessLog())
	r.GET("/health", func(c *gin.Context) { c.JSON(200, gin.H{"status": "ok"}) })

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	r.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("期望 200，实际 %d", w.Code)
	}
	out := buf.String()
	if !strings.Contains(out, "[GIN]") {
		t.Errorf("期望日志包含 [GIN] 前缀，实际: %q", out)
	}
	if !strings.Contains(out, "GET") || !strings.Contains(out, "/health") {
		t.Errorf("期望日志包含方法和路径，实际: %q", out)
	}
}

// TestBusinessAccessLog_SilencesNoRoute 验证扫描器探测不存在路径时：
//   - 响应仍是 404（行为不退化，扫描器拿不到额外信息）
//   - 日志 buffer 为空（完全静默，不污染 journalctl）
func TestBusinessAccessLog_SilencesNoRoute(t *testing.T) {
	buf, reset := captureOutput()
	defer reset()

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(BusinessAccessLog())
	r.GET("/health", func(c *gin.Context) { c.JSON(200, gin.H{"status": "ok"}) })

	// 模拟扫描器访问典型的探测路径
	for _, p := range []string{"/mcp", "/.well-known/mcp.json", "/actuator/health", "/HNAP1", "/sdk"} {
		w := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, p, nil)
		r.ServeHTTP(w, req)

		if w.Code != 404 {
			t.Errorf("路径 %s 期望 404（NoRoute 行为不退化），实际 %d", p, w.Code)
		}
	}

	if buf.Len() != 0 {
		t.Errorf("期望 NoRoute 请求静默，但输出了: %q", buf.String())
	}
}
