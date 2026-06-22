package ratelimit

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func makeMW(max int) gin.HandlerFunc {
	return New(Options{
		Window:  time.Minute,
		Max:     max,
		KeyFunc: func(c *gin.Context) string { return "k" },
		Redis:   nil, // 内存降级
	})
}

func TestLimiter_AllowsUnderLimit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/x", makeMW(5), func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	for i := 0; i < 5; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
		if w.Code != 200 {
			t.Fatalf("第 %d 次期望 200，实际 %d", i+1, w.Code)
		}
	}
}

func TestLimiter_BlocksOverLimit(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/x", makeMW(3), func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	for i := 0; i < 3; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
		if w.Code != 200 {
			t.Fatalf("第 %d 次期望 200，实际 %d", i+1, w.Code)
		}
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
	if w.Code != 429 {
		t.Fatalf("第 4 次期望 429，实际 %d", w.Code)
	}
}

// 并发安全：多 goroutine 同时打不会数据竞争 panic。
func TestLimiter_ConcurrentSafe(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/x", makeMW(100), func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
			if w.Code != http.StatusOK && w.Code != http.StatusTooManyRequests {
				t.Errorf("意外状态码 %d", w.Code)
			}
		}()
	}
	wg.Wait()
}

// 不同 key 互不影响。
func TestLimiter_PerKeyIsolation(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	i := 0
	r.GET("/x", New(Options{
		Window: time.Minute,
		Max:    1,
		KeyFunc: func(c *gin.Context) string {
			i++
			return string(rune('a' + i)) // 每次不同 key
		},
	}), func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	for n := 0; n < 5; n++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
		if w.Code != 200 {
			t.Fatalf("第 %d 次不同 key 期望 200，实际 %d", n+1, w.Code)
		}
	}
}
