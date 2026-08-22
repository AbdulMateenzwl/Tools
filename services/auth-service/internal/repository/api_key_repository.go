package repository

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// APIKeyRepository owns the api_keys table. User identity lives in Cognito,
// so there is no longer a users table or a foreign key to one — user_id here
// is the Cognito "sub".
type APIKeyRepository struct {
	db *pgxpool.Pool
}

func NewAPIKeyRepository(db *pgxpool.Pool) *APIKeyRepository {
	return &APIKeyRepository{db: db}
}

// CreateAPIKey stores a hashed API key associated with a Cognito user.
func (r *APIKeyRepository) CreateAPIKey(ctx context.Context, userID, hashedKey, prefix string) error {
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
