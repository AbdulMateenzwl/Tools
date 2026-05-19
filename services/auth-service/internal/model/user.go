package model

import "time"

type User struct {
    ID           string    `db:"id"            json:"id"`
    Email        string    `db:"email"         json:"email"`
    PasswordHash string    `db:"password_hash" json:"-"`
    Role         string    `db:"role"          json:"role"`
    CreatedAt    time.Time `db:"created_at"    json:"created_at"`
}

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