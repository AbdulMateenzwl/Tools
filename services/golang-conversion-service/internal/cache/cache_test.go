package cache

import (
	"context"
	"testing"
	"time"
)

func TestKey(t *testing.T) {
	t.Run("is deterministic", func(t *testing.T) {
		if Key("json-to-xml", "abc") != Key("json-to-xml", "abc") {
			t.Error("same operation and input produced different keys")
		}
	})

	t.Run("separates operations", func(t *testing.T) {
		// Without this the same payload converted two ways would collide and
		// json-to-xml would serve an xml-to-json result.
		if Key("json-to-xml", "abc") == Key("xml-to-json", "abc") {
			t.Error("different operations produced the same key")
		}
	})

	t.Run("separates inputs", func(t *testing.T) {
		if Key("json-to-xml", "a") == Key("json-to-xml", "b") {
			t.Error("different inputs produced the same key")
		}
	})

	t.Run("is namespaced", func(t *testing.T) {
		if got := Key("op", "in"); got[:5] != "conv:" {
			t.Errorf("key %q is not prefixed conv:", got)
		}
	})
}

func TestParseTTL(t *testing.T) {
	tests := []struct {
		name string
		env  string
		want time.Duration
	}{
		{"unset falls back to 60m", "", 60 * time.Minute},
		{"valid value is honoured", "5", 5 * time.Minute},
		{"non-numeric falls back", "abc", 60 * time.Minute},
		{"zero falls back", "0", 60 * time.Minute},
		{"negative falls back", "-5", 60 * time.Minute},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("CACHE_TTL_MINUTES", tt.env)
			if got := parseTTL(); got != tt.want {
				t.Errorf("parseTTL() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestMemoryCache(t *testing.T) {
	ctx := context.Background()

	t.Run("returns what was stored", func(t *testing.T) {
		c := NewMemoryCache()
		c.Set(ctx, "k", "v")

		got, ok := c.Get(ctx, "k")
		if !ok || got != "v" {
			t.Errorf("Get = (%q, %v), want (\"v\", true)", got, ok)
		}
	})

	t.Run("reports a miss for an unknown key", func(t *testing.T) {
		c := NewMemoryCache()
		if _, ok := c.Get(ctx, "absent"); ok {
			t.Error("expected a miss")
		}
	})

	t.Run("expired entries are a miss", func(t *testing.T) {
		c := NewMemoryCache()
		c.ttl = -time.Second // already expired on write
		c.Set(ctx, "k", "v")

		if _, ok := c.Get(ctx, "k"); ok {
			t.Error("expired entry was returned")
		}
	})

	t.Run("concurrent use does not race", func(t *testing.T) {
		// Meaningful under `go test -race`.
		c := NewMemoryCache()
		done := make(chan struct{})
		for i := 0; i < 8; i++ {
			go func() {
				for j := 0; j < 100; j++ {
					c.Set(ctx, "k", "v")
					c.Get(ctx, "k")
				}
				done <- struct{}{}
			}()
		}
		for i := 0; i < 8; i++ {
			<-done
		}
	})
}

// MemoryCache must remain usable wherever a Store is expected.
var _ Store = (*MemoryCache)(nil)
var _ Store = (*RedisCache)(nil)
