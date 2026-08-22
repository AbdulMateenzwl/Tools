package cache

import "context"

// Store is the cache behaviour the handlers actually depend on. Both
// RedisCache and MemoryCache satisfy it, which lets the handlers be tested
// without a Redis and lets the service run locally with no infrastructure.
type Store interface {
	Get(ctx context.Context, key string) (string, bool)
	Set(ctx context.Context, key, value string)
}
