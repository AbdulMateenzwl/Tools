package middleware

import (
    "net/http"
    "os"
    "strings"

    "github.com/golang-jwt/jwt/v5"
    "github.com/gin-gonic/gin"
)

func RequireAuth() gin.HandlerFunc {
    return func(c *gin.Context) {
        bearer := c.GetHeader("Authorization")
        parts := strings.SplitN(bearer, " ", 2)
        if len(parts) != 2 || parts[0] != "Bearer" {
            c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "missing token"})
            return
        }

        secret := os.Getenv("JWT_SECRET")
        token, err := jwt.Parse(parts[1], func(t *jwt.Token) (interface{}, error) {
            if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
                return nil, jwt.ErrSignatureInvalid
            }
            return []byte(secret), nil
        })

        if err != nil || !token.Valid {
            c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
            return
        }

        claims, ok := token.Claims.(jwt.MapClaims)
        if !ok {
            c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "invalid claims"})
            return
        }

        c.Set("user_id", claims["sub"])
        c.Set("email", claims["email"])
        c.Set("role", claims["role"])
        c.Next()
    }
}