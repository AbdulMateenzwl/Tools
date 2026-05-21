package cache

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisCache struct {
	client *redis.Client
	ttl    time.Duration
}

func NewRedisCache(client *redis.Client) *RedisCache {
	ttl := parseTTL()
	return &RedisCache{client: client, ttl: ttl}
}

// parseTTL reads CACHE_TTL_MINUTES from env, defaults to 60
func parseTTL() time.Duration {
	val := os.Getenv("CACHE_TTL_MINUTES")
	if val == "" {
		return 60 * time.Minute
	}
	minutes, err := strconv.Atoi(val)
	if err != nil || minutes <= 0 {
		return 60 * time.Minute
	}
	return time.Duration(minutes) * time.Minute
}

func Key(operation, input string) string {
	hash := sha256.Sum256([]byte(operation + ":" + input))
	return fmt.Sprintf("conv:%x", hash)
}

func (c *RedisCache) Get(ctx context.Context, key string) (string, bool) {
	val, err := c.client.Get(ctx, key).Result()
	if err != nil {
		return "", false
	}
	return val, true
}

func (c *RedisCache) Set(ctx context.Context, key, value string) {
	c.client.Set(ctx, key, value, c.ttl)
}