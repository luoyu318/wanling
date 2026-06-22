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
}

func newMemoryStore() *memoryStore {
	return &memoryStore{entries: make(map[string]*entry)}
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

// New 返回限流中间件。
func New(opts Options) gin.HandlerFunc {
	store := newMemoryStore()
	return func(c *gin.Context) {
		key := opts.KeyFunc(c)
		var allowed bool
		if opts.Redis != nil {
			// Redis 固定窗口：INCR + EXPIRE。失败则 fail-open 降级。
			allowed = redisAllow(opts.Redis, opts.Prefix+key, opts.Window, opts.Max)
		} else {
			allowed = store.allow(key, opts.Window, opts.Max)
		}
		if !allowed {
			c.AbortWithStatusJSON(http.StatusTooManyRequests, gin.H{"error": "操作过于频繁，稍后重试"})
			return
		}
		c.Next()
	}
}

// redisAllow Redis 固定窗口。首次 INCR 后 EXPIRE；超限返回 false。
// Redis 报错时 fail-open（允许通过，避免 Redis 抖动阻塞业务）。
func redisAllow(rdb *redis.Client, key string, window time.Duration, max int) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	n, err := rdb.Incr(ctx, key).Result()
	if err != nil {
		return true // fail-open
	}
	if n == 1 {
		_ = rdb.Expire(ctx, key, window).Err()
	}
	return n <= int64(max)
}
