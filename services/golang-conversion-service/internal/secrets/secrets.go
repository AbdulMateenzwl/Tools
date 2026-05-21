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

	s.RedisPassword, err = getSecret(ctx, client, "convertx/redis/password")
	if err != nil {
		return nil, fmt.Errorf("get redis password: %w", err)
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