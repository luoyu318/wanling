// Package ratelimit 提供固定窗口限流中间件。
// Redis 可用时走 Redis（多实例一致），不可用时降级内存（单实例有效）。
package ratelimit

import (
	"context"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

// Options 限流配置。
type Options struct {
	Window  time.Duration               // 时间窗口
	Max     int                         // 窗口内最大请求数
	KeyFunc func(c *gin.Context) string // 提取限流 key（IP/userID）
	Redis   *redis.Client               // 可选，nil 时内存降级
	Prefix  string                      // Redis key 前缀，如 "rl:pair_get:"
}

// entry 单个 key 的固定窗口计数。
type entry struct {
	mu      sync.Mutex
	count   int
	windows time.Time
}

// memoryStore 内存固定窗口实现（Redis 降级路径）。
type memoryStore struct {
	mu      sync.Mutex
	entries map[string]*entry
	stopCh  chan struct{}
}

func newMemoryStore() *memoryStore {
	m := &memoryStore{
		entries: make(map[string]*entry),
		stopCh:  make(chan struct{}),
	}
	go m.cleanupLoop()
	return m
}

// cleanupLoop 后台定期清理过期 entry，防止大量不同 key 导致内存线性增长。
func (m *memoryStore) cleanupLoop() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			m.sweep()
		case <-m.stopCh:
			return
		}
	}
}

// sweep 删除窗口超过 5 分钟未活跃的 entry。
func (m *memoryStore) sweep() {
	m.mu.Lock()
	defer m.mu.Unlock()
	cutoff := time.Now().Add(-5 * time.Minute)
	for key, e := range m.entries {
		if e.windows.Before(cutoff) {
			delete(m.entries, key)
		}
	}
}

// stop 终止清理 goroutine，供优雅关闭与测试使用。
func (m *memoryStore) stop() {
	close(m.stopCh)
}

func (m *memoryStore) allow(key string, window time.Duration, max int) bool {
	m.mu.Lock()
	e, ok := m.entries[key]
	if !ok {
		e = &entry{}
		m.entries[key] = e
	}
	m.mu.Unlock()

	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	if now.Sub(e.windows) >= window {
		// 进入新窗口，重置计数
		e.windows = now
		e.count = 0
	}
	if e.count >= max {
		return false
	}
	e.count++
	return true
}

// Limiter 固定窗口限流器（非 gin 中间件场景使用，如 WS readPump）。
type Limiter struct {
	store  *memoryStore
	window time.Duration
	max    int
}

// NewLimiter 创建限流器。window=时间窗口，max=窗口内最大请求数。
// 内部启动 cleanup goroutine，Stop 时终止。
func NewLimiter(window time.Duration, max int) *Limiter {
	return &Limiter{store: newMemoryStore(), window: window, max: max}
}

// Allow 检查 key 是否在限流窗口内允许通过。
func (l *Limiter) Allow(key string) bool {
	return l.store.allow(key, l.window, l.max)
}

// Stop 终止清理 goroutine，供优雅关闭使用。
func (l *Limiter) Stop() {
	l.store.stop()
}

// New 返回限流中间件。
func New(opts Options) gin.HandlerFunc {
	store := newMemoryStore()
	return func(c *gin.Context) {
		key := opts.KeyFunc(c)
		var allowed bool
		if opts.Redis != nil {
			// Redis 固定窗口：INCR + EXPIRE。
			// 区分两种"非 true"语义:
			//   - 超限 (allowed=false, err=nil):Redis 已权威判定,直接拒绝,不走内存
			//     (否则内存是新 store count=0,会放行超限请求 — 等于绕过限流)
			//   - 报错 (err!=nil):Redis 抖动期回退内存计数(fail-soft),
			//     避免 Redis 故障导致限流完全失效(单实例下内存计数=全局计数)
			redisOK, err := redisAllow(opts.Redis, opts.Prefix+key, opts.Window, opts.Max)
			if err != nil {
				allowed = store.allow(key, opts.Window, opts.Max)
			} else {
				allowed = redisOK
			}
		} else {
			allowed = store.allow(key, opts.Window, opts.Max)
		}
		if !allowed {
			// 不调 handler.Err 避免循环依赖(handler 可能 import ratelimit),手写 envelope JSON。
			// 形态与 handler.Err 429 完全一致:{ok: false, error: {code, message}}
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{
				"ok": false,
				"error": gin.H{
					"code":    "rate_limited",
					"message": "操作过于频繁，稍后重试",
				},
			})
			return
		}
		c.Next()
	}
}

// redisAllow Redis 固定窗口。首次 INCR 后 EXPIRE；超限返回 (false, nil)。
//
// 返回 (allowed, err) 区分两种 false 语义,让上层 New 决定是拒绝还是降级:
//   - allowed=false, err=nil:Redis 计数已超限,调用方应拒绝(不再走内存)
//   - allowed=false, err!=nil:Redis 报错,调用方回退内存计数
func redisAllow(rdb *redis.Client, key string, window time.Duration, max int) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	n, err := rdb.Incr(ctx, key).Result()
	if err != nil {
		return false, err
	}
	if n == 1 {
		_ = rdb.Expire(ctx, key, window).Err()
	}
	return n <= int64(max), nil
}
