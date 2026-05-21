package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/convertx/auth-service/internal/handler"
	"github.com/convertx/auth-service/internal/middleware"
	"github.com/convertx/auth-service/internal/repository"
	"github.com/convertx/auth-service/internal/secrets"
	"github.com/convertx/auth-service/internal/service"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
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

	// Validate JWT secret is not empty
	if s.JWTSecret == "" {
		log.Fatal("jwt_secret is empty — cannot start")
	}

	// Inject JWT secret into env so middleware can read it
	os.Setenv("JWT_SECRET", s.JWTSecret)

	dbURL := fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=disable",
		os.Getenv("DB_USER"),
		s.DBPassword,
		os.Getenv("DB_HOST"),
		os.Getenv("DB_NAME"),
	)

	db, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		log.Fatalf("connect to postgres: %v", err)
	}
	defer db.Close()

	if err := db.Ping(ctx); err != nil {
		log.Fatalf("ping postgres: %v", err)
	}
	log.Println("connected to postgres")

	// ── Redis ──────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr:     os.Getenv("REDIS_HOST"),
		Password: s.RedisPassword,
	})
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("connect to redis: %v", err)
	}
	log.Println("connected to redis")

	// ── Migrations ─────────────────────────────────────────────
	if err := runMigrations(db, ctx); err != nil {
		log.Fatalf("run migrations: %v", err)
	}

	// ── Wire up layers ─────────────────────────────────────────
	userRepo := repository.NewUserRepository(db)
	authSvc := service.NewAuthService(userRepo, rdb)
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
	protected.Use(middleware.RequireAuth())
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
		`CREATE TABLE IF NOT EXISTS users (
            id            UUID PRIMARY KEY,
            email         VARCHAR(255) UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            role          VARCHAR(50) NOT NULL DEFAULT 'free',
            created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )`,
		`CREATE TABLE IF NOT EXISTS api_keys (
            id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            key_hash   TEXT UNIQUE NOT NULL,
            prefix     VARCHAR(20) NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )`,
		`CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)`,
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
