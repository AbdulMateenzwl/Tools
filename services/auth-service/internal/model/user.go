package model

type RegisterRequest struct {
    Email    string `json:"email"    binding:"required,email"`
    Password string `json:"password" binding:"required,min=8"`
}

type LoginRequest struct {
    Email    string `json:"email"    binding:"required,email"`
    Password string `json:"password" binding:"required"`
}

type TokenResponse struct {
    AccessToken  string `json:"access_token"`
    RefreshToken string `json:"refresh_token"`
    ExpiresIn    int    `json:"expires_in"`
}

type RefreshRequest struct {
    RefreshToken string `json:"refresh_token" binding:"required"`
}

type APIKeyResponse struct {
    APIKey string `json:"api_key"`
}