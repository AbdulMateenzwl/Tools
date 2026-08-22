package cache

import (
	"context"
	"sync"
	"time"
)

// MemoryCache is a process-local Store used for local development and tests.
// It honours the same CACHE_TTL_MINUTES setting as RedisCache so cache
// behaviour is identical to production; expired entries are dropped lazily on
// read, which is fine for a cache that dies with the process.
type MemoryCache struct {
	mu    sync.RWMutex
	ttl   time.Duration
	items map[string]memoryItem
}

type memoryItem struct {
	value     string
	expiresAt time.Time
}

func NewMemoryCache() *MemoryCache {
	return &MemoryCache{ttl: parseTTL(), items: make(map[string]memoryItem)}
}

func (c *MemoryCache) Get(_ context.Context, key string) (string, bool) {
	c.mu.RLock()
	item, ok := c.items[key]
	c.mu.RUnlock()

	if !ok || time.Now().After(item.expiresAt) {
		return "", false
	}
	return item.value, true
}

func (c *MemoryCache) Set(_ context.Context, key, value string) {
	c.mu.Lock()
	c.items[key] = memoryItem{value: value, expiresAt: time.Now().Add(c.ttl)}
	c.mu.Unlock()
}
