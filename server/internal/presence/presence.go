package presence

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

const (
	keyPrefix = "presence:"
	ttl       = 60 * time.Second
)

type Presence struct {
	rdb *redis.Client
}

func New(rdb *redis.Client) *Presence {
	return &Presence{rdb: rdb}
}

func (p *Presence) key(role, id string) string {
	return keyPrefix + role + ":" + id
}

// Online 标记某 role+id 上线：写一个带 ttl 的 presence key。
// 幂等（SET 覆盖），心跳续期 RefreshTTL 复用同一实现。
func (p *Presence) Online(role, id string) error {
	if p == nil || p.rdb == nil {
		return nil
	}
	ctx := context.Background()
	return p.rdb.Set(ctx, p.key(role, id), "1", ttl).Err()
}

func (p *Presence) Offline(role, id string) error {
	if p == nil || p.rdb == nil {
		return nil
	}
	ctx := context.Background()
	return p.rdb.Del(ctx, p.key(role, id)).Err()
}

func (p *Presence) IsOnline(role, id string) bool {
	if p == nil || p.rdb == nil {
		return false
	}
	ctx := context.Background()
	val, err := p.rdb.Exists(ctx, p.key(role, id)).Result()
	if err != nil {
		return false
	}
	return val == 1
}

// RefreshTTL 心跳时续期 presence key。
//
// 用 SET 而非 EXPIRE：EXPIRE 对已失效/丢失的 key 返回 0 且不重建，导致 Redis
// 清空或 server 重启后（此时既有 WS 连接不会断开），存活连接的 presence key
// 永久丢失，agent 表现为「离线但能正常收发消息」。SET 幂等且能重建 key，
// key 丢失后一次心跳即自愈。实现与 Online 一致。
func (p *Presence) RefreshTTL(role, id string) error {
	if p == nil || p.rdb == nil {
		return nil
	}
	ctx := context.Background()
	return p.rdb.Set(ctx, p.key(role, id), "1", ttl).Err()
}

func (p *Presence) Ping() error {
	if p == nil || p.rdb == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return p.rdb.Ping(ctx).Err()
}
