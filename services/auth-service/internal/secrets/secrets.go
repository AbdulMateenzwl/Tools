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
	DBPassword    string
	RedisPassword string
	JWTSecret     string
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

	s.RedisPassword, err = getSecret(ctx, client, "convertx/redis/password")
	if err != nil {
		return nil, fmt.Errorf("get redis password: %w", err)
	}

	s.JWTSecret, err = getSecret(ctx, client, "convertx/auth/jwt_secret")
	if err != nil {
		return nil, fmt.Errorf("get jwt secret: %w", err)
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