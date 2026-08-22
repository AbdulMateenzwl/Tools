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
	RedisPassword string
	// RedisEndpoint is host:port for the ElastiCache cluster. ElastiCache is
	// assigned a port dynamically by LocalStack, so it cannot live in a
	// ConfigMap — the bootstrap resolves it and publishes it here.
	RedisEndpoint string
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
			if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
				o.BaseEndpoint = aws.String(endpoint)
			}
		},
	)

	s := &Secrets{}

	// Absent is legitimate and is the normal case here: ElastiCache is created
	// without an auth token, and SecretsManager cannot store an empty string,
	// so "no AUTH" is represented by the secret simply not existing. go-redis
	// sends no AUTH command when the password is empty.
	s.RedisPassword = getSecretOrEnv(ctx, client, "convertx/redis/password", "REDIS_PASSWORD")

	s.RedisEndpoint = getSecretOrEnv(ctx, client, "convertx/redis/endpoint", "REDIS_HOST")
	if s.RedisEndpoint == "" {
		return nil, fmt.Errorf("redis endpoint unresolved: neither convertx/redis/endpoint nor REDIS_HOST is set")
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
// variable, so a cluster still running a self-hosted Redis keeps working.
func getSecretOrEnv(ctx context.Context, client *secretsmanager.Client, name, envKey string) string {
	if val, err := getSecret(ctx, client, name); err == nil && val != "" {
		return val
	}
	return os.Getenv(envKey)
}
