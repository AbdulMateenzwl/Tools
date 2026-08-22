package secrets

import (
	"context"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
)

type Secrets struct {
	// RDS still backs the api_keys table. The users table is gone — Cognito
	// is the identity store now.
	DBUser     string
	DBPassword string
	// DBEndpoint is host:port. RDS gets a dynamic port from LocalStack, so it
	// cannot live in a ConfigMap; the bootstrap resolves and publishes it.
	DBEndpoint string

	CognitoUserPoolID string
	CognitoClientID   string
	// CognitoJWKSURL is where RS256 signing keys are fetched from. LocalStack
	// serves these on a different path than real AWS, hence a stored value
	// rather than one derived from the pool id.
	CognitoJWKSURL string
}

func Load(ctx context.Context) (*Secrets, error) {
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(os.Getenv("AWS_REGION")),
	)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}

	client := secretsmanager.NewFromConfig(cfg,
		func(o *secretsmanager.Options) {
			// Point to LocalStack endpoint if set
			if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
				o.BaseEndpoint = aws.String(endpoint)
			}
		},
	)

	s := &Secrets{}

	s.DBPassword, err = getSecret(ctx, client, "convertx/postgres/password")
	if err != nil {
		return nil, fmt.Errorf("get db password: %w", err)
	}

	s.CognitoUserPoolID, err = getSecret(ctx, client, "convertx/cognito/user_pool_id")
	if err != nil {
		return nil, fmt.Errorf("get cognito user pool id: %w", err)
	}

	s.CognitoClientID, err = getSecret(ctx, client, "convertx/cognito/client_id")
	if err != nil {
		return nil, fmt.Errorf("get cognito client id: %w", err)
	}

	s.CognitoJWKSURL, err = getSecret(ctx, client, "convertx/cognito/jwks_url")
	if err != nil {
		return nil, fmt.Errorf("get cognito jwks url: %w", err)
	}

	s.DBUser = getSecretOrEnv(ctx, client, "convertx/postgres/username", "DB_USER")
	if s.DBUser == "" {
		return nil, fmt.Errorf("db user unresolved: neither convertx/postgres/username nor DB_USER is set")
	}

	s.DBEndpoint = getSecretOrEnv(ctx, client, "convertx/postgres/endpoint", "DB_HOST")
	if s.DBEndpoint == "" {
		return nil, fmt.Errorf("db endpoint unresolved: neither convertx/postgres/endpoint nor DB_HOST is set")
	}

	return s, nil
}

func getSecret(ctx context.Context, client *secretsmanager.Client, name string) (string, error) {
	result, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(name),
	})
	if err != nil {
		return "", fmt.Errorf("get secret %s: %w", name, err)
	}
	return aws.ToString(result.SecretString), nil
}

// getSecretOrEnv prefers SecretsManager and falls back to an environment
// variable, so a cluster still running self-hosted postgres keeps working.
func getSecretOrEnv(ctx context.Context, client *secretsmanager.Client, name, envKey string) string {
	if val, err := getSecret(ctx, client, name); err == nil && val != "" {
		return val
	}
	return os.Getenv(envKey)
}
