package repository

import (
	"encoding/hex"
	"testing"
)

func TestSigningKeyRepo_Ensure_Idempotent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewSigningKeyRepo(db)
	k1, err := repo.Ensure(t.Context())
	if err != nil || k1 == nil {
		t.Fatalf("Ensure: %v", err)
	}
	if k1.PrivateKey == "" || k1.PublicKey == "" {
		t.Fatalf("keypair 应非空")
	}
	k2, err := repo.Ensure(t.Context())
	if err != nil || k2 == nil {
		t.Fatalf("Ensure 二次: %v", err)
	}
	if k2.PrivateKey != k1.PrivateKey || k2.PublicKey != k1.PublicKey {
		t.Errorf("Ensure 应幂等(同一密钥),实际变了")
	}
	if _, err := hex.DecodeString(k1.PrivateKey); err != nil {
		t.Errorf("private_key 应为 hex: %v", err)
	}
	if _, err := hex.DecodeString(k1.PublicKey); err != nil {
		t.Errorf("public_key 应为 hex: %v", err)
	}
}

func TestSigningKeyRepo_Get_Empty_ReturnsNilNil(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewSigningKeyRepo(db)
	k, err := repo.Get(t.Context())
	if err != nil || k != nil {
		t.Errorf("无密钥时期望 nil,nil,实际 %v %v", k, err)
	}
}
