package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"

	"github.com/convertx/auth-service/internal/cognito"
	"github.com/convertx/auth-service/internal/model"
	"github.com/convertx/auth-service/internal/repository"
)

// Identity errors now originate in the cognito package; these aliases keep the
// handler's errors.Is checks working unchanged.
var (
	ErrUserAlreadyExists  = cognito.ErrUserExists
	ErrInvalidCredentials = cognito.ErrInvalidCredentials
	ErrInvalidToken       = cognito.ErrInvalidToken
)

type AuthService struct {
	apiKeys *repository.APIKeyRepository
	idp     *cognito.Client
}

func NewAuthService(apiKeys *repository.APIKeyRepository, idp *cognito.Client) *AuthService {
	return &AuthService{apiKeys: apiKeys, idp: idp}
}

func (s *AuthService) Register(ctx context.Context, req *model.RegisterRequest) error {
	return s.idp.Register(ctx, req.Email, req.Password)
}

func (s *AuthService) Login(ctx context.Context, req *model.LoginRequest) (*model.TokenResponse, error) {
	tokens, err := s.idp.Login(ctx, req.Email, req.Password)
	if err != nil {
		return nil, err
	}
	return toTokenResponse(tokens), nil
}

func (s *AuthService) RefreshToken(ctx context.Context, refreshToken string) (*model.TokenResponse, error) {
	tokens, err := s.idp.Refresh(ctx, refreshToken)
	if err != nil {
		return nil, err
	}

	// Only retire the old token when a genuinely new one came back. Cognito's
	// refresh flow normally reissues just the access token, in which case the
	// caller keeps using the same refresh token — revoking it there would lock
	// them out. This is why refresh tokens no longer rotate on every use the
	// way the Redis implementation forced them to.
	if tokens.RefreshToken != "" && tokens.RefreshToken != refreshToken {
		if err := s.idp.Revoke(ctx, refreshToken); err != nil {
			log.Printf("revoke superseded refresh token: %v", err)
		}
	}

	return toTokenResponse(tokens), nil
}

// GetUser resolves the caller's profile. Cognito access tokens carry no email
// claim, so /me needs this round trip.
func (s *AuthService) GetUser(ctx context.Context, accessToken string) (*cognito.User, error) {
	return s.idp.GetUser(ctx, accessToken)
}

// GenerateAPIKey is unchanged: Cognito has no API key concept, so these stay
// in RDS. userID is the Cognito "sub".
func (s *AuthService) GenerateAPIKey(ctx context.Context, userID string) (*model.APIKeyResponse, error) {
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

	if err := s.apiKeys.CreateAPIKey(ctx, userID, hashedKey, prefix); err != nil {
		return nil, err
	}

	// Return the raw key — shown only once
	return &model.APIKeyResponse{APIKey: apiKey}, nil
}

func toTokenResponse(t *cognito.Tokens) *model.TokenResponse {
	return &model.TokenResponse{
		AccessToken:  t.AccessToken,
		RefreshToken: t.RefreshToken,
		ExpiresIn:    int(t.ExpiresIn),
	}
}
