package ratelimit

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
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

// TestLimiter_RedisDownFallbackToMemory 验证 Redis 故障时回退内存计数。
//
// 构造一个连不上的 Redis（指向无效端口），redisAllow 的 INCR 会失败返回 false，
// 上层应回退到内存 store 继续限流，而非 fail-open 放行所有请求。
// 这是 H5 修复的核心断言：安全限流在 Redis 抖动期不失效。
func TestLimiter_RedisDownFallbackToMemory(t *testing.T) {
	gin.SetMode(gin.TestMode)
	// 指向无效端口，INCR 必然连接失败
	badRdb := redis.NewClient(&redis.Options{
		Addr:        "127.0.0.1:1", // 1 端口通常无服务，连接被拒
		DialTimeout: 200 * time.Millisecond,
	})

	r := gin.New()
	r.GET("/x", New(Options{
		Window:  time.Minute,
		Max:     2,
		KeyFunc: func(c *gin.Context) string { return "fixed-key" },
		Redis:   badRdb,
	}), func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	// 前 2 次内存兜底允许通过（Redis 失败 → 内存计数 1, 2）
	for i := 0; i < 2; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
		if w.Code != 200 {
			t.Fatalf("Redis 故障期第 %d 次期望 200（内存兜底），实际 %d", i+1, w.Code)
		}
	}
	// 第 3 次应被内存计数拒绝（429），证明限流未因 Redis 故障失效
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
	if w.Code != 429 {
		t.Fatalf("Redis 故障期第 3 次期望 429（内存兜底超限），实际 %d", w.Code)
	}
}

// TestLimiter_RedisOverLimitRejectsDirectly 验证 Redis 计数已超限时直接拒绝,
// 不走内存降级(否则内存是新 store count=0,会放行超限请求 — 等于绕过限流)。
//
// 这是 H5 修复引入的回归 bug 的回归测试:
//
//	修前 redisAllow 返 bool 无法区分"超限"和"报错",New() 把超限也当 fail-soft 走内存
//	修后 redisAllow 返 (bool, error),超限 (false, nil) 直接拒绝,不走内存
//
// 用 miniredis 起进程内 Redis,事先 INCR 把 key 推到 max,然后发请求期望 429。
func TestLimiter_RedisOverLimitRejectsDirectly(t *testing.T) {
	gin.SetMode(gin.TestMode)
	mr, err := miniredis.Run()
	if err != nil {
		t.Fatalf("起 miniredis 失败: %v", err)
	}
	defer mr.Close()

	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()

	r := gin.New()
	r.GET("/x", New(Options{
		Window:  time.Minute,
		Max:     3,
		KeyFunc: func(c *gin.Context) string { return "fixed-key" },
		Redis:   rdb,
		Prefix:  "rl:test:",
	}), func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })

	// 前 3 次 Redis 计数 1/2/3,均放行
	for i := 0; i < 3; i++ {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
		if w.Code != 200 {
			t.Fatalf("第 %d 次期望 200,实际 %d", i+1, w.Code)
		}
	}
	// 第 4 次:Redis 计数 4 > max=3 → redisAllow 返 (false, nil) → 直接拒绝
	// 回归路径(修前):redisAllow 返 false → New() 当 fail-soft 走内存 → 内存 count=0 放行
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("GET", "/x", nil))
	if w.Code != 429 {
		t.Fatalf("Redis 计数已超限,第 4 次期望 429(直接拒绝不走内存),实际 %d", w.Code)
	}

	// 额外校验:Redis 计数确实是 4(不是被内存拦的)
	count, err := rdb.Get(context.Background(), "rl:test:fixed-key").Int()
	if err != nil {
		t.Fatalf("查 Redis 计数失败: %v", err)
	}
	if count != 4 {
		t.Fatalf("Redis 计数应为 4(超限请求也被 INCR),实际 %d", count)
	}
}

// TestMemoryStore_SweepRemovesStaleEntries 验证清理删掉过期 entry。
func TestMemoryStore_SweepRemovesStaleEntries(t *testing.T) {
	m := newMemoryStore()
	defer m.stop()

	// 手动塞入一个过期 entry
	m.mu.Lock()
	m.entries["old-ip"] = &entry{
		count:   5,
		windows: time.Now().Add(-10 * time.Minute), // 10 分钟前，远超 5 分钟阈值
	}
	m.entries["recent-ip"] = &entry{
		count:   1,
		windows: time.Now().Add(-1 * time.Minute), // 1 分钟前，活跃
	}
	m.mu.Unlock()

	m.sweep()

	m.mu.Lock()
	defer m.mu.Unlock()
	if _, exists := m.entries["old-ip"]; exists {
		t.Error("过期 entry 应被清理")
	}
	if _, exists := m.entries["recent-ip"]; !exists {
		t.Error("活跃 entry 不应被清理")
	}
}

// TestMemoryStore_SweepEmptyMap_NoError 验证空 map 清理不 panic。
func TestMemoryStore_SweepEmptyMap_NoError(t *testing.T) {
	m := newMemoryStore()
	defer m.stop()
	m.sweep() // 不应 panic
}

// TestMemoryStore_StopTerminatesGoroutine 验证 stop() 关闭清理 goroutine。
func TestMemoryStore_StopTerminatesGoroutine(t *testing.T) {
	m := newMemoryStore()
	m.stop()
	// stop 后 sweep 仍可手动调用（不依赖 goroutine）
	m.sweep()
}
