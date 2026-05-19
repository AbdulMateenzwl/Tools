package main

import (
    "context"
    "fmt"
    "log"
    "os"

    "github.com/convertx/auth-service/internal/handler"
    "github.com/convertx/auth-service/internal/middleware"
    "github.com/convertx/auth-service/internal/repository"
    "github.com/convertx/auth-service/internal/service"
    "github.com/gin-gonic/gin"
    "github.com/jackc/pgx/v5/pgxpool"
    "github.com/redis/go-redis/v9"
)

func main() {
    ctx := context.Background()

    // PostgreSQL connection
    dbURL := fmt.Sprintf("postgres://%s:%s@%s/%s",
        os.Getenv("DB_USER"),
        os.Getenv("DB_PASSWORD"),
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

    // Redis connection
    rdb := redis.NewClient(&redis.Options{
        Addr:     os.Getenv("REDIS_HOST"),
        Password: os.Getenv("REDIS_PASSWORD"),
    })
    if err := rdb.Ping(ctx).Err(); err != nil {
        log.Fatalf("connect to redis: %v", err)
    }
    log.Println("connected to redis")

    // Run DB migrations
    if err := runMigrations(db, ctx); err != nil {
        log.Fatalf("run migrations: %v", err)
    }

    // Wire up layers
    userRepo := repository.NewUserRepository(db)
    authSvc := service.NewAuthService(userRepo, rdb)
    authHandler := handler.NewAuthHandler(authSvc)

    // Router
    r := gin.New()
    r.Use(gin.Logger())
    r.Use(gin.Recovery())

    // Public routes
    v1 := r.Group("/api/v1/auth")
    {
        v1.GET("/health", authHandler.Health)
        v1.POST("/register", authHandler.Register)
        v1.POST("/login", authHandler.Login)
        v1.POST("/refresh", authHandler.RefreshToken)
    }

    // Protected routes
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

// runMigrations creates tables if they don't exist
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