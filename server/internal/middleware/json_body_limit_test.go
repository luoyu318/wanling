package middleware

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
)

const testLimit int64 = 1024

// readBodyAfterLimit 把请求穿过 JSONBodyLimit 中间件后由 handler 完整读 body,
// 返回读到的错误(模拟真实 handler 消费 body 的行为)。
func readBodyAfterLimit(t *testing.T, mw gin.HandlerFunc, path, contentType string, body []byte) error {
	t.Helper()
	var readErr error
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(mw)
	r.POST(path, func(c *gin.Context) {
		_, readErr = io.ReadAll(c.Request.Body)
		c.Status(http.StatusOK)
	})
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	r.ServeHTTP(w, req)
	return readErr
}

func TestJSONBodyLimit_超越JSON限制被截断(t *testing.T) {
	big := bytes.Repeat([]byte("a"), int(2*testLimit))
	err := readBodyAfterLimit(t, JSONBodyLimit(testLimit), "/api/echo", "application/json", big)
	var maxErr *http.MaxBytesError
	if !errors.As(err, &maxErr) {
		t.Fatalf("JSON body 超限应报 MaxBytesError, got %v", err)
	}
}

func TestJSONBodyLimit_未超限完整读取(t *testing.T) {
	small := bytes.Repeat([]byte("a"), 100)
	if err := readBodyAfterLimit(t, JSONBodyLimit(testLimit), "/api/echo", "application/json", small); err != nil {
		t.Fatalf("未超限应完整读取, got %v", err)
	}
}

func TestJSONBodyLimit_multipart不受JSON限制(t *testing.T) {
	big := bytes.Repeat([]byte("a"), int(2*testLimit))
	ct := "multipart/form-data; boundary=----wanling"
	if err := readBodyAfterLimit(t, JSONBodyLimit(testLimit), "/api/mini-programs", ct, big); err != nil {
		t.Fatalf("multipart 上传不受 JSON 限制(由 handler 自带 MaxBytesReader 拦截), got %v", err)
	}
}

func TestJSONBodyLimit_上传路由按路径豁免(t *testing.T) {
	big := bytes.Repeat([]byte("a"), int(2*testLimit))
	if err := readBodyAfterLimit(t, JSONBodyLimit(testLimit), "/api/upload", "application/json", big); err != nil {
		t.Fatalf("/api/upload 路径应豁免, got %v", err)
	}
}

func TestJSONBodyLimit_ws路由豁免(t *testing.T) {
	big := bytes.Repeat([]byte("a"), int(2*testLimit))
	if err := readBodyAfterLimit(t, JSONBodyLimit(testLimit), "/ws", "", big); err != nil {
		t.Fatalf("/ws 路径应豁免, got %v", err)
	}
}
