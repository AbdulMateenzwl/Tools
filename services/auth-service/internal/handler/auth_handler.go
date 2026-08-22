package handler

import (
    "errors"
    "net/http"
    "strings"

    "github.com/convertx/auth-service/internal/model"
    "github.com/convertx/auth-service/internal/service"
    "github.com/gin-gonic/gin"
)

type AuthHandler struct {
    authService *service.AuthService
}

func NewAuthHandler(authService *service.AuthService) *AuthHandler {
    return &AuthHandler{authService: authService}
}

func (h *AuthHandler) Register(c *gin.Context) {
    var req model.RegisterRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    if err := h.authService.Register(c.Request.Context(), &req); err != nil {
        if errors.Is(err, service.ErrUserAlreadyExists) {
            c.JSON(http.StatusConflict, gin.H{"error": "email already registered"})
            return
        }
        c.JSON(http.StatusInternalServerError, gin.H{"error": "registration failed"})
        return
    }

    c.JSON(http.StatusCreated, gin.H{"message": "registered successfully"})
}

func (h *AuthHandler) Login(c *gin.Context) {
    var req model.LoginRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    tokens, err := h.authService.Login(c.Request.Context(), &req)
    if err != nil {
        if errors.Is(err, service.ErrInvalidCredentials) {
            c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid email or password"})
            return
        }
        c.JSON(http.StatusInternalServerError, gin.H{"error": "login failed"})
        return
    }

    c.JSON(http.StatusOK, tokens)
}

func (h *AuthHandler) RefreshToken(c *gin.Context) {
    var req model.RefreshRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
        return
    }

    tokens, err := h.authService.RefreshToken(c.Request.Context(), req.RefreshToken)
    if err != nil {
        c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid or expired refresh token"})
        return
    }

    c.JSON(http.StatusOK, tokens)
}

func (h *AuthHandler) GenerateAPIKey(c *gin.Context) {
    // User ID is set by auth middleware
    userID, exists := c.Get("user_id")
    if !exists {
        c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
        return
    }

    apiKey, err := h.authService.GenerateAPIKey(c.Request.Context(), userID.(string))
    if err != nil {
        c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate api key"})
        return
    }

    c.JSON(http.StatusCreated, apiKey)
}

func (h *AuthHandler) Me(c *gin.Context) {
    userID, _ := c.Get("user_id")
    role, _ := c.Get("role")

    // Cognito access tokens carry no email claim, so it comes from GetUser
    // rather than straight off the token like it used to.
    var email string
    if raw, ok := c.Get("access_token"); ok {
        if token, ok := raw.(string); ok {
            user, err := h.authService.GetUser(c.Request.Context(), token)
            if err != nil {
                c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
                return
            }
            email = user.Email
            if user.Sub != "" {
                userID = user.Sub
            }
        }
    }

    c.JSON(http.StatusOK, gin.H{
        "id":    userID,
        "email": email,
        "role":  role,
    })
}

// Health check endpoint for K8s liveness/readiness probes
func (h *AuthHandler) Health(c *gin.Context) {
    c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// extractToken pulls JWT from Authorization: Bearer <token> header
func extractToken(c *gin.Context) string {
    bearer := c.GetHeader("Authorization")
    parts := strings.SplitN(bearer, " ", 2)
    if len(parts) == 2 && parts[0] == "Bearer" {
        return parts[1]
    }
    return ""
}