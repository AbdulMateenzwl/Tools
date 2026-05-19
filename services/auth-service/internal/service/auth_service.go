package service

import (
    "context"
    "crypto/rand"
    "crypto/sha256"
    "encoding/hex"
    "errors"
    "fmt"
    "os"
    "time"

    "github.com/convertx/auth-service/internal/model"
    "github.com/convertx/auth-service/internal/repository"
    "github.com/golang-jwt/jwt/v5"
    "github.com/google/uuid"
    "github.com/redis/go-redis/v9"
    "golang.org/x/crypto/bcrypt"
)

var (
    ErrUserAlreadyExists = errors.New("user already exists")
    ErrInvalidCredentials = errors.New("invalid credentials")
    ErrInvalidToken      = errors.New("invalid token")
)

type AuthService struct {
    userRepo *repository.UserRepository
    redis    *redis.Client
}

func NewAuthService(userRepo *repository.UserRepository, redis *redis.Client) *AuthService {
    return &AuthService{
        userRepo: userRepo,
        redis:    redis,
    }
}

// Register creates a new user
func (s *AuthService) Register(ctx context.Context, req *model.RegisterRequest) error {
    // Check if user already exists
    existing, _ := s.userRepo.GetUserByEmail(ctx, req.Email)
    if existing != nil {
        return ErrUserAlreadyExists
    }

    // Hash password
    hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
    if err != nil {
        return fmt.Errorf("hash password: %w", err)
    }

    user := &model.User{
        ID:           uuid.New().String(),
        Email:        req.Email,
        PasswordHash: string(hash),
        Role:         "free",
        CreatedAt:    time.Now().UTC(),
    }

    return s.userRepo.CreateUser(ctx, user)
}

// Login validates credentials and returns tokens
func (s *AuthService) Login(ctx context.Context, req *model.LoginRequest) (*model.TokenResponse, error) {
    user, err := s.userRepo.GetUserByEmail(ctx, req.Email)
    if err != nil {
        return nil, ErrInvalidCredentials
    }

    if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
        return nil, ErrInvalidCredentials
    }

    return s.generateTokenPair(ctx, user)
}

// RefreshToken issues a new access token from a valid refresh token
func (s *AuthService) RefreshToken(ctx context.Context, refreshToken string) (*model.TokenResponse, error) {
    // Look up refresh token in Redis
    userID, err := s.redis.Get(ctx, "refresh:"+refreshToken).Result()
    if err != nil {
        return nil, ErrInvalidToken
    }

    user, err := s.userRepo.GetUserByID(ctx, userID)
    if err != nil {
        return nil, ErrInvalidToken
    }

    // Delete old refresh token
    s.redis.Del(ctx, "refresh:"+refreshToken)

    return s.generateTokenPair(ctx, user)
}

// GenerateAPIKey creates a new API key for a user
func (s *AuthService) GenerateAPIKey(ctx context.Context, userID string) (*model.APIKeyResponse, error) {
    // Generate 32 random bytes
    raw := make([]byte, 32)
    if _, err := rand.Read(raw); err != nil {
        return nil, fmt.Errorf("generate api key: %w", err)
    }

    // Format: cx_<hex>
    apiKey := "cx_" + hex.EncodeToString(raw)
    prefix := apiKey[:10]

    // Store hashed version in DB
    hash := sha256.Sum256([]byte(apiKey))
    hashedKey := hex.EncodeToString(hash[:])

    if err := s.userRepo.CreateAPIKey(ctx, userID, hashedKey, prefix); err != nil {
        return nil, err
    }

    // Return the raw key — shown only once
    return &model.APIKeyResponse{APIKey: apiKey}, nil
}

// generateTokenPair creates access + refresh token pair
func (s *AuthService) generateTokenPair(ctx context.Context, user *model.User) (*model.TokenResponse, error) {
    secret := os.Getenv("JWT_SECRET")

    // Access token — 15 minutes
    accessClaims := jwt.MapClaims{
        "sub":  user.ID,
        "email": user.Email,
        "role": user.Role,
        "iss":  user.ID,
        "exp":  time.Now().Add(15 * time.Minute).Unix(),
        "iat":  time.Now().Unix(),
    }
    accessToken, err := jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims).SignedString([]byte(secret))
    if err != nil {
        return nil, fmt.Errorf("sign access token: %w", err)
    }

    // Refresh token — 7 days, stored in Redis
    refreshRaw := make([]byte, 32)
    rand.Read(refreshRaw)
    refreshToken := hex.EncodeToString(refreshRaw)

    err = s.redis.Set(ctx,
        "refresh:"+refreshToken,
        user.ID,
        7*24*time.Hour,
    ).Err()
    if err != nil {
        return nil, fmt.Errorf("store refresh token: %w", err)
    }

    return &model.TokenResponse{
        AccessToken:  accessToken,
        RefreshToken: refreshToken,
        ExpiresIn:    900, // 15 minutes in seconds
    }, nil
}