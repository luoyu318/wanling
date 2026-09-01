package repository

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"

	"github.com/wanling/server/internal/model"
)

// SigningKeyRepo 小程序包签名密钥对数据访问层。
// mp_signing_key 为单行表(id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK(id)),
// 私钥仅存 server 永不下发,公钥经端点下发给 APP 验签。
type SigningKeyRepo struct {
	queryExecutor
}

func NewSigningKeyRepo(db *sql.DB) *SigningKeyRepo {
	return &SigningKeyRepo{queryExecutor: queryExecutor{db: db}}
}

// Get 查当前密钥对;无则 nil,nil。
func (r *SigningKeyRepo) Get(ctx context.Context) (*model.SigningKey, error) {
	const q = `SELECT private_key, public_key FROM mp_signing_key WHERE id`
	var k model.SigningKey
	if err := r.queryRow(ctx, q).Scan(&k.PrivateKey, &k.PublicKey); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("signing key get: %w", err)
	}
	return &k, nil
}

// Ensure 取签名密钥对,无则生成入库;并发安全:ON CONFLICT (id) DO NOTHING 后重查。
// 返回值保证非 nil(插入后仍查不到视为异常,fail fast)。
func (r *SigningKeyRepo) Ensure(ctx context.Context) (*model.SigningKey, error) {
	k, err := r.Get(ctx)
	if err != nil {
		return nil, err
	}
	if k != nil {
		return k, nil
	}

	priv, pub, err := generateSigningKeypair()
	if err != nil {
		return nil, fmt.Errorf("signing key generate: %w", err)
	}
	const q = `INSERT INTO mp_signing_key (private_key, public_key) VALUES ($1, $2)
		ON CONFLICT (id) DO NOTHING`
	if _, err := r.exec(ctx, q, priv, pub); err != nil {
		return nil, fmt.Errorf("signing key insert: %w", err)
	}

	// 重查:并发时可能拿到先插入方的密钥,保证全程单钥
	k, err = r.Get(ctx)
	if err != nil {
		return nil, err
	}
	if k == nil {
		return nil, fmt.Errorf("signing key ensure: 插入后仍无密钥")
	}
	return k, nil
}

// generateSigningKeypair 生成 hex 编码密钥对。
// TODO(M3-Task2): 替换为 miniprogram.GenerateKeypair
func generateSigningKeypair() (privHex, pubHex string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", fmt.Errorf("ed25519 generate: %w", err)
	}
	return hex.EncodeToString(priv), hex.EncodeToString(pub), nil
}
