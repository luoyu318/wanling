package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

type RefreshData struct {
	UserID string `json:"user_id"`
	Role   string `json:"role"`
	Ver    int    `json:"ver"`
}

type TokenStore struct {
	rdb *redis.Client
}

func NewTokenStore(rdb *redis.Client) *TokenStore {
	return &TokenStore{rdb: rdb}
}

func (s *TokenStore) CreateRefresh(ctx context.Context, token, userID, role string, ver int, ttl time.Duration) error {
	key := "refresh:" + hashToken(token)
	data := RefreshData{UserID: userID, Role: role, Ver: ver}
	val, _ := json.Marshal(data)
	return s.rdb.Set(ctx, key, val, ttl).Err()
}

func (s *TokenStore) GetRefresh(ctx context.Context, token string) (*RefreshData, error) {
	key := "refresh:" + hashToken(token)
	val, err := s.rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var data RefreshData
	if err := json.Unmarshal([]byte(val), &data); err != nil {
		return nil, fmt.Errorf("refresh token unmarshal: %w", err)
	}
	return &data, nil
}

func (s *TokenStore) DeleteRefresh(ctx context.Context, token string) error {
	key := "refresh:" + hashToken(token)
	return s.rdb.Del(ctx, key).Err()
}

func (s *TokenStore) BlacklistToken(ctx context.Context, jti string, ttl time.Duration) error {
	key := "blacklist:" + jti
	return s.rdb.Set(ctx, key, "1", ttl).Err()
}

func (s *TokenStore) IsBlacklisted(ctx context.Context, jti string) (bool, error) {
	key := "blacklist:" + jti
	_, err := s.rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (s *TokenStore) GetTokenVersion(ctx context.Context, userID string) (int, error) {
	key := "tokenver:" + userID
	val, err := s.rdb.Get(ctx, key).Int()
	if err == redis.Nil {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return val, nil
}

func (s *TokenStore) IncrTokenVersion(ctx context.Context, userID string) (int, error) {
	key := "tokenver:" + userID
	val, err := s.rdb.Incr(ctx, key).Result()
	if err != nil {
		return 0, err
	}
	return int(val), nil
}

func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}

func GenerateRefreshToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(fmt.Sprintf("crypto/rand failed: %v", err))
	}
	return hex.EncodeToString(b)
}
