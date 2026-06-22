package handler

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/wanling/server/internal/auth"
)

// AuthMiddleware JWT 鉴权中间件，支持按角色过滤
func AuthMiddleware(jwtSecret string, allowedRoles ...string) gin.HandlerFunc {
	return func(c *gin.Context) {
		header := c.GetHeader("Authorization")
		if header == "" || !strings.HasPrefix(header, "Bearer ") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "未提供认证信息"})
			return
		}

		tokenStr := strings.TrimPrefix(header, "Bearer ")
		claims, err := auth.ParseToken(jwtSecret, tokenStr)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "无效 token"})
			return
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
				c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"error": "无权限"})
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

// GetClaims 从上下文中获取 JWT 声明
func GetClaims(c *gin.Context) *auth.Claims {
	return c.MustGet("claims").(*auth.Claims)
}
