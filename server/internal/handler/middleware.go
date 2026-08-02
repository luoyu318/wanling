package handler

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/wanling/server/internal/auth"
	logpkg "github.com/wanling/server/internal/log"
)

// AuthMiddlewareWithStore JWT 鉴权 + Redis 黑名单/tokenver 检查（store 为 nil 时降级为纯 JWT 校验）。
func AuthMiddlewareWithStore(jwtSecret string, store *auth.TokenStore, allowedRoles ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		header := c.GetHeader("Authorization")
		if header == "" || !strings.HasPrefix(header, "Bearer ") {
			Err(c, http.StatusUnauthorized, "unauthorized", "未提供认证信息")
			c.Abort()
			return
		}

		tokenStr := strings.TrimPrefix(header, "Bearer ")
		claims, err := auth.ParseToken(jwtSecret, tokenStr)
		if err != nil {
			Err(c, http.StatusUnauthorized, "unauthorized", "无效 token")
			c.Abort()
			return
		}

		if claims.ID != "" && store != nil {
			black, err := store.IsBlacklisted(c.Request.Context(), claims.ID)
			if err != nil {
				logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
					"黑名单检查失败,fail-open 放行", "jti", claims.ID, "err", err)
			} else if black {
				Err(c, http.StatusUnauthorized, "token_revoked", "token 已被撤销")
				c.Abort()
				return
			}
		}

		if claims.Role == "user" && store != nil {
			curVer, err := store.GetTokenVersion(c.Request.Context(), claims.Subject)
			if err != nil {
				logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
					"tokenver 检查失败,fail-open 放行", "user_id", claims.Subject, "err", err)
			} else if curVer != claims.Version {
				Err(c, http.StatusUnauthorized, "token_version_mismatch", "token 已失效")
				c.Abort()
				return
			}
		}

		if len(allowedRoles) > 0 {
			matched := false
			for _, role := range allowedRoles {
				if claims.Role == role {
					matched = true
					break
				}
			}
			if !matched {
				Err(c, http.StatusForbidden, "forbidden", "无权限")
				c.Abort()
				return
			}
		}

		c.Set("claims", claims)
		c.Set("userID", claims.Subject)
		c.Set("role", claims.Role)
		if claims.Owner != "" {
			c.Set("ownerID", claims.Owner)
		}
		c.Next()
	}
}

// AuthMiddleware 旧签名（不做 Redis 检查），保留兼容。
func AuthMiddleware(jwtSecret string, allowedRoles ...string) gin.HandlerFunc {
	return AuthMiddlewareWithStore(jwtSecret, nil, allowedRoles...)
}
