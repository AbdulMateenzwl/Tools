package cache

import (
    "context"
    "crypto/sha256"
    "fmt"
    "time"

    "github.com/redis/go-redis/v9"
)

const ttl = 1 * time.Hour

type RedisCache struct {
    client *redis.Client
}

func NewRedisCache(client *redis.Client) *RedisCache {
    return &RedisCache{client: client}
}

// Key generates a cache key from the operation name and input
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
    // fire and forget — cache failure should never break a conversion
    c.client.Set(ctx, key, value, ttl)
}