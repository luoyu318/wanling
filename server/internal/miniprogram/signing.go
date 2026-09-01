package miniprogram

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// GenerateKeypair 生成 ed25519 密钥对,hex 编码返回(privHex, pubHex)。
// 私钥仅存 server DB,公钥经端点下发给 APP 验签。
func GenerateKeypair() (privHex, pubHex string, err error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", fmt.Errorf("ed25519 generate: %w", err)
	}
	return hex.EncodeToString(priv), hex.EncodeToString(pub), nil
}

// Sign 用 hex 编码私钥对 data 签名,返回 hex 编码签名。
// fail fast:私钥 hex 非法或长度不符均返回错误。
func Sign(privHex string, data []byte) (sigHex string, err error) {
	priv, err := hex.DecodeString(privHex)
	if err != nil {
		return "", fmt.Errorf("私钥 hex 非法: %w", err)
	}
	if len(priv) != ed25519.PrivateKeySize {
		return "", fmt.Errorf("私钥长度 %d != %d", len(priv), ed25519.PrivateKeySize)
	}
	return hex.EncodeToString(ed25519.Sign(ed25519.PrivateKey(priv), data)), nil
}

// Verify 用 hex 编码公钥验证 data 与 hex 编码签名。
// fail fast:hex 解码/长度/验证失败均返回错误,验证通过返回 nil。
func Verify(pubHex string, data []byte, sigHex string) error {
	pub, err := hex.DecodeString(pubHex)
	if err != nil {
		return fmt.Errorf("公钥 hex 非法: %w", err)
	}
	sig, err := hex.DecodeString(sigHex)
	if err != nil {
		return fmt.Errorf("签名 hex 非法: %w", err)
	}
	if len(pub) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("公钥/签名长度非法")
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), data, sig) {
		return fmt.Errorf("签名验证失败")
	}
	return nil
}
