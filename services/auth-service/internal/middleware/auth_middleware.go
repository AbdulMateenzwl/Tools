package middleware

import (
	"net/http"
	"strings"

	"github.com/convertx/auth-service/internal/cognito"
	"github.com/convertx/auth-service/internal/jwks"
	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

// RequireAuth verifies a Cognito-issued RS256 access token against the pool's
// JWKS. This replaces the previous HS256 check against a shared secret.
//
// userPoolID is checked against the token's "iss" claim by suffix rather than
// by exact string match. The issuer host reflects however the identity
// provider was addressed when the token was minted — LocalStack emits
// "localhost.localstack.cloud:4566", real AWS emits
// "cognito-idp.<region>.amazonaws.com" — so pinning the whole URL breaks the
// moment the address changes. The property actually worth enforcing is that
// the token came from *this* user pool, and the pool id is what carries it.
func RequireAuth(keys *jwks.Cache, userPoolID string) gin.HandlerFunc {
	return func(c *gin.Context) {
		bearer := c.GetHeader("Authorization")
		parts := strings.SplitN(bearer, " ", 2)
		if len(parts) != 2 || parts[0] != "Bearer" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing token"})
			return
		}
		raw := parts[1]

		token, err := jwt.Parse(raw, keys.Keyfunc,
			jwt.WithValidMethods([]string{"RS256"}))
		if err != nil || !token.Valid {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
			return
		}

		claims, ok := token.Claims.(jwt.MapClaims)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid claims"})
			return
		}

		// Cognito issues both id and access tokens from the same pool. Only an
		// access token authorises an API call, and only it can be passed to
		// GetUser, so reject anything else explicitly.
		if use, _ := claims["token_use"].(string); use != "access" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "expected an access token"})
			return
		}

		// Ties the token to our user pool without depending on the host part.
		if userPoolID != "" {
			iss, _ := claims["iss"].(string)
			if !strings.HasSuffix(iss, "/"+userPoolID) {
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "token issued by an unknown pool"})
				return
			}
		}

		c.Set("user_id", claims["sub"])
		c.Set("role", roleFromGroups(claims))
		// Access tokens carry no email claim; handlers that need one call
		// GetUser with this.
		c.Set("access_token", raw)
		c.Next()
	}
}

// roleFromGroups maps the cognito:groups claim onto the single role string the
// API used to read from users.role.
func roleFromGroups(claims jwt.MapClaims) string {
	groups, ok := claims["cognito:groups"].([]interface{})
	if !ok || len(groups) == 0 {
		return cognito.DefaultGroup
	}
	if s, ok := groups[0].(string); ok && s != "" {
		return s
	}
	return cognito.DefaultGroup
}
