package auth

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newTestTokenStore(t *testing.T) (*TokenStore, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { rdb.Close() })
	return NewTokenStore(rdb), mr
}

const testRefreshTTL = 30 * 24 * time.Hour

func TestCreateAndGetRefresh(t *testing.T) {
	store, _ := newTestTokenStore(t)
	ctx := context.Background()

	err := store.CreateRefresh(ctx, "token-abc", "user-1", "user", 3, testRefreshTTL)
	if err != nil {
		t.Fatalf("CreateRefresh: %v", err)
	}

	data, err := store.GetRefresh(ctx, "token-abc")
	if err != nil {
		t.Fatalf("GetRefresh: %v", err)
	}
	if data.UserID != "user-1" || data.Role != "user" || data.Ver != 3 {
		t.Fatalf("unexpected data: %+v", data)
	}
}

func TestGetRefreshNotExist(t *testing.T) {
	store, _ := newTestTokenStore(t)
	ctx := context.Background()

	data, err := store.GetRefresh(ctx, "nonexistent")
	if err != nil {
		t.Fatalf("expected nil error for missing key, got: %v", err)
	}
	if data != (*RefreshData)(nil) {
		t.Fatalf("expected nil data for missing key")
	}
}

func TestDeleteRefresh(t *testing.T) {
	store, _ := newTestTokenStore(t)
	ctx := context.Background()

	store.CreateRefresh(ctx, "token-abc", "user-1", "user", 3, testRefreshTTL)
	store.DeleteRefresh(ctx, "token-abc")

	data, _ := store.GetRefresh(ctx, "token-abc")
	if data != nil {
		t.Fatalf("expected nil after delete, got: %+v", data)
	}
}

func TestRefreshRotation(t *testing.T) {
	store, _ := newTestTokenStore(t)
	ctx := context.Background()

	store.CreateRefresh(ctx, "old-token", "user-1", "user", 3, testRefreshTTL)
	store.DeleteRefresh(ctx, "old-token")
	store.CreateRefresh(ctx, "new-token", "user-1", "user", 3, testRefreshTTL)

	old, _ := store.GetRefresh(ctx, "old-token")
	if old != nil {
		t.Fatal("old token should be deleted after rotation")
	}
	newData, _ := store.GetRefresh(ctx, "new-token")
	if newData == nil {
		t.Fatal("new token should exist after rotation")
	}
}

func TestRefreshExpiry(t *testing.T) {
	store, mr := newTestTokenStore(t)
	ctx := context.Background()

	store.CreateRefresh(ctx, "token-x", "user-1", "user", 0, 2*time.Hour)
	store.BlacklistToken(ctx, "jti-x", 1*time.Hour)

	data, _ := store.GetRefresh(ctx, "token-x")
	if data == nil {
		t.Fatal("expected token to exist before fast-forward")
	}

	mr.FastForward(3 * time.Hour)

	data2, _ := store.GetRefresh(ctx, "token-x")
	if data2 != nil {
		t.Fatal("expected refresh token to expire after fast-forward")
	}

	black, _ := store.IsBlacklisted(ctx, "jti-x")
	if black {
		t.Fatal("expected blacklist entry to expire after fast-forward")
	}
}

func TestBlacklistToken(t *testing.T) {
	store, _ := newTestTokenStore(t)
	ctx := context.Background()

	store.BlacklistToken(ctx, "jti-123", 2*time.Hour)

	black, err := store.IsBlacklisted(ctx, "jti-123")
	if err != nil {
		t.Fatalf("IsBlacklisted: %v", err)
	}
	if !black {
		t.Fatal("expected jti-123 to be blacklisted")
	}

	black2, _ := store.IsBlacklisted(ctx, "jti-not-blacklisted")
	if black2 {
		t.Fatal("expected jti-not-blacklisted to not be blacklisted")
	}
}

func TestTokenVersion(t *testing.T) {
	store, _ := newTestTokenStore(t)
	ctx := context.Background()

	ver, err := store.GetTokenVersion(ctx, "user-1")
	if err != nil {
		t.Fatalf("GetTokenVersion: %v", err)
	}
	if ver != 0 {
		t.Fatalf("expected 0 for new user, got %d", ver)
	}

	ver, err = store.IncrTokenVersion(ctx, "user-1")
	if err != nil {
		t.Fatalf("IncrTokenVersion: %v", err)
	}
	if ver != 1 {
		t.Fatalf("expected 1 after first incr, got %d", ver)
	}

	ver, _ = store.GetTokenVersion(ctx, "user-1")
	if ver != 1 {
		t.Fatalf("expected 1 after incr, got %d", ver)
	}

	store.IncrTokenVersion(ctx, "user-1")
	ver, _ = store.GetTokenVersion(ctx, "user-1")
	if ver != 2 {
		t.Fatalf("expected 2 after second incr, got %d", ver)
	}
}

func TestGenerateTokenWithJTIandVer(t *testing.T) {
	secret := "test-secret"
	token, err := GenerateToken(secret, "user-1", "user", "", 2*time.Hour, "jti-abc", 3)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}

	claims, err := ParseToken(secret, token)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}
	if claims.ID != "jti-abc" {
		t.Fatalf("expected jti=jti-abc, got %s", claims.ID)
	}
	if claims.Version != 3 {
		t.Fatalf("expected ver=3, got %d", claims.Version)
	}
}
