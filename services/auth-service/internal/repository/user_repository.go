package repository

import (
    "context"
    "fmt"

    "github.com/convertx/auth-service/internal/model"
    "github.com/jackc/pgx/v5/pgxpool"
)

type UserRepository struct {
    db *pgxpool.Pool
}

func NewUserRepository(db *pgxpool.Pool) *UserRepository {
    return &UserRepository{db: db}
}

func (r *UserRepository) CreateUser(ctx context.Context, user *model.User) error {
    query := `
        INSERT INTO users (id, email, password_hash, role, created_at)
        VALUES ($1, $2, $3, $4, $5)
    `
    _, err := r.db.Exec(ctx, query,
        user.ID,
        user.Email,
        user.PasswordHash,
        user.Role,
        user.CreatedAt,
    )
    if err != nil {
        return fmt.Errorf("create user: %w", err)
    }
    return nil
}

func (r *UserRepository) GetUserByEmail(ctx context.Context, email string) (*model.User, error) {
    query := `
        SELECT id, email, password_hash, role, created_at
        FROM users
        WHERE email = $1
    `
    user := &model.User{}
    err := r.db.QueryRow(ctx, query, email).Scan(
        &user.ID,
        &user.Email,
        &user.PasswordHash,
        &user.Role,
        &user.CreatedAt,
    )
    if err != nil {
        return nil, fmt.Errorf("get user by email: %w", err)
    }
    return user, nil
}

func (r *UserRepository) GetUserByID(ctx context.Context, id string) (*model.User, error) {
    query := `
        SELECT id, email, password_hash, role, created_at
        FROM users
        WHERE id = $1
    `
    user := &model.User{}
    err := r.db.QueryRow(ctx, query, id).Scan(
        &user.ID,
        &user.Email,
        &user.PasswordHash,
        &user.Role,
        &user.CreatedAt,
    )
    if err != nil {
        return nil, fmt.Errorf("get user by id: %w", err)
    }
    return user, nil
}

// CreateAPIKey stores a hashed API key associated with a user
func (r *UserRepository) CreateAPIKey(ctx context.Context, userID, hashedKey, prefix string) error {
    query := `
        INSERT INTO api_keys (id, user_id, key_hash, prefix, created_at)
        VALUES (gen_random_uuid(), $1, $2, $3, NOW())
    `
    _, err := r.db.Exec(ctx, query, userID, hashedKey, prefix)
    if err != nil {
        return fmt.Errorf("create api key: %w", err)
    }
    return nil
}