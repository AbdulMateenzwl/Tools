package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"

	"github.com/convertx/auth-service/internal/cognito"
	"github.com/convertx/auth-service/internal/handler"
	"github.com/convertx/auth-service/internal/jwks"
	"github.com/convertx/auth-service/internal/middleware"
	"github.com/convertx/auth-service/internal/repository"
	"github.com/convertx/auth-service/internal/secrets"
	"github.com/convertx/auth-service/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
)

func main() {
	ctx := context.Background()

	// ── Load secrets from SecretsManager ──────────────────────
	log.Println("loading secrets from SecretsManager...")
	s, err := secrets.Load(ctx)
	if err != nil {
		log.Fatalf("load secrets: %v", err)
	}
	log.Println("secrets loaded successfully")

	// ── Postgres (RDS) ─────────────────────────────────────────
	// Only backs api_keys now; user identity lives in Cognito.
	// Built via net/url so a password containing @ or / cannot corrupt the DSN.
	dbURL := (&url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(s.DBUser, s.DBPassword),
		Host:     s.DBEndpoint,
		Path:     "/" + os.Getenv("DB_NAME"),
		RawQuery: "sslmode=disable",
	}).String()

	db, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		log.Fatalf("connect to postgres: %v", err)
	}
	defer db.Close()

	if err := db.Ping(ctx); err != nil {
		log.Fatalf("ping postgres: %v", err)
	}
	log.Println("connected to postgres")

	if err := runMigrations(db, ctx); err != nil {
		log.Fatalf("run migrations: %v", err)
	}

	// ── Cognito ────────────────────────────────────────────────
	idp, err := cognito.New(ctx, s.CognitoUserPoolID, s.CognitoClientID)
	if err != nil {
		log.Fatalf("init cognito: %v", err)
	}
	log.Printf("cognito user pool %s ready", s.CognitoUserPoolID)

	// Fetch the signing keys up front so a bad JWKS URL fails at startup
	// rather than on the first authenticated request.
	keys := jwks.New(s.CognitoJWKSURL)
	if err := keys.Warm(); err != nil {
		log.Fatalf("fetch jwks from %s: %v", s.CognitoJWKSURL, err)
	}
	log.Printf("jwks loaded from %s", s.CognitoJWKSURL)

	// ── Wire up layers ─────────────────────────────────────────
	apiKeyRepo := repository.NewAPIKeyRepository(db)
	authSvc := service.NewAuthService(apiKeyRepo, idp)
	authHandler := handler.NewAuthHandler(authSvc)

	// ── Router ─────────────────────────────────────────────────
	r := gin.New()
	r.MaxMultipartMemory = 1 << 20 // 1MB
	r.Use(func(c *gin.Context) {
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 1<<20)
		c.Next()
	})
	r.Use(gin.Logger())
	r.Use(gin.Recovery())

	v1 := r.Group("/api/v1/auth")
	{
		v1.GET("/health", authHandler.Health)
		v1.POST("/register", authHandler.Register)
		v1.POST("/login", authHandler.Login)
		v1.POST("/refresh", authHandler.RefreshToken)
	}

	protected := v1.Group("")
	protected.Use(middleware.RequireAuth(keys, s.CognitoUserPoolID))
	{
		protected.GET("/me", authHandler.Me)
		protected.POST("/api-key", authHandler.GenerateAPIKey)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("auth service starting on :%s", port)
	if err := r.Run(":" + port); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func runMigrations(db *pgxpool.Pool, ctx context.Context) error {
	queries := []string{
		// user_id holds a Cognito "sub". There is no users table to reference
		// any more, so no foreign key.
		`CREATE TABLE IF NOT EXISTS api_keys (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id    UUID NOT NULL,
            key_hash   TEXT UNIQUE NOT NULL,
            prefix     VARCHAR(20) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )`,
		// Drops the FK left behind on databases created before Cognito.
		// The orphaned users table is left in place rather than dropped
		// automatically — remove it by hand once you are satisfied.
		`ALTER TABLE api_keys DROP CONSTRAINT IF EXISTS api_keys_user_id_fkey`,
		`CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON api_keys(user_id)`,
		`CREATE INDEX IF NOT EXISTS idx_api_keys_hash ON api_keys(key_hash)`,
	}

	for _, q := range queries {
		if _, err := db.Exec(ctx, q); err != nil {
			return fmt.Errorf("migration failed: %w", err)
		}
	}

	log.Println("migrations complete")
	return nil
}
