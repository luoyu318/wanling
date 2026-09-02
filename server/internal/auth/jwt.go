package auth

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// SubKeyPrefix agent 子密钥凭据前缀。AgentToken 以此前缀路由到子密钥校验分支,
// WS/技能侧文档同样写死此前缀。
const SubKeyPrefix = "wlsk_"

// Claims 自定义 JWT 声明，包含角色和所属者信息
type Claims struct {
	jwt.RegisteredClaims
	Role    string `json:"role"`
	Owner   string `json:"owner,omitempty"`
	Version int    `json:"ver,omitempty"`
	KeyKind string `json:"key_kind,omitempty"` // "master"|"sub";空串视为 master(向后兼容)
	KeyID   string `json:"key_id,omitempty"`
}

// GenerateToken 生成 JWT token
func GenerateToken(secret, subject, role, owner string, ttl time.Duration, jti string, ver int) (string, error) {
	now := time.Now()
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   subject,
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
			IssuedAt:  jwt.NewNumericDate(now),
			ID:        jti,
		},
		Role:    role,
		Owner:   owner,
		Version: ver,
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(secret))
}

// GenerateAgentToken 生成 agent 专用 JWT。keyKind 取 "master"|"sub" 标识凭据来源,
// keyID 仅子密钥场景非空（子密钥 ID）。与 GenerateToken 分离,user token 永不携带 key_kind。
func GenerateAgentToken(secret, subject, owner string, ttl time.Duration, jti string, ver int, keyKind, keyID string) (string, error) {
	now := time.Now()
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   subject,
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
			IssuedAt:  jwt.NewNumericDate(now),
			ID:        jti,
		},
		Role:    "agent",
		Owner:   owner,
		Version: ver,
		KeyKind: keyKind,
		KeyID:   keyID,
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString([]byte(secret))
}

// ParseToken 解析并验证 JWT token
func ParseToken(secret, tokenStr string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
		return []byte(secret), nil
	})
	if err != nil {
		return nil, err
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, errors.New("无效 token")
	}
	return claims, nil
}
