// Package jwks fetches and caches a JSON Web Key Set and exposes a keyfunc
// for verifying RS256 tokens. Cognito signs with rotating RSA keys, so the
// public key must be looked up by "kid" rather than shared as a secret.
package jwks

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	N   string `json:"n"`
	E   string `json:"e"`
	Alg string `json:"alg"`
	Use string `json:"use"`
}

type document struct {
	Keys []jwk `json:"keys"`
}

// Cache holds the parsed key set. A miss on an unknown kid triggers a refetch,
// rate-limited by minRefresh so a bogus kid cannot be used to hammer the IdP.
type Cache struct {
	url        string
	ttl        time.Duration
	minRefresh time.Duration
	httpClient *http.Client

	mu        sync.RWMutex
	keys      map[string]*rsa.PublicKey
	fetchedAt time.Time
}

func New(url string) *Cache {
	return &Cache{
		url:        url,
		ttl:        1 * time.Hour,
		minRefresh: 1 * time.Minute,
		httpClient: &http.Client{Timeout: 10 * time.Second},
		keys:       make(map[string]*rsa.PublicKey),
	}
}

// Keyfunc satisfies jwt.Keyfunc.
func (c *Cache) Keyfunc(token *jwt.Token) (interface{}, error) {
	if _, ok := token.Method.(*jwt.SigningMethodRSA); !ok {
		return nil, fmt.Errorf("unexpected signing method %q, want RSA", token.Header["alg"])
	}

	kid, _ := token.Header["kid"].(string)
	if kid == "" {
		return nil, fmt.Errorf("token has no kid header")
	}

	if key, stale := c.lookup(kid); key != nil && !stale {
		return key, nil
	}

	if err := c.refresh(); err != nil {
		// Fall back to a stale key rather than failing every request while
		// the IdP is briefly unreachable.
		if key, _ := c.lookup(kid); key != nil {
			return key, nil
		}
		return nil, fmt.Errorf("refresh jwks: %w", err)
	}

	if key, _ := c.lookup(kid); key != nil {
		return key, nil
	}
	return nil, fmt.Errorf("no key for kid %q", kid)
}

func (c *Cache) lookup(kid string) (key *rsa.PublicKey, stale bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.keys[kid], time.Since(c.fetchedAt) > c.ttl
}

func (c *Cache) refresh() error {
	c.mu.Lock()
	if time.Since(c.fetchedAt) < c.minRefresh {
		c.mu.Unlock()
		return nil
	}
	c.mu.Unlock()

	resp, err := c.httpClient.Get(c.url)
	if err != nil {
		return fmt.Errorf("get %s: %w", c.url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("get %s: status %d", c.url, resp.StatusCode)
	}

	var doc document
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return fmt.Errorf("decode jwks: %w", err)
	}

	parsed := make(map[string]*rsa.PublicKey, len(doc.Keys))
	for _, k := range doc.Keys {
		if k.Kty != "RSA" || k.Kid == "" {
			continue
		}
		key, err := parseRSA(k)
		if err != nil {
			return fmt.Errorf("parse key %s: %w", k.Kid, err)
		}
		parsed[k.Kid] = key
	}
	if len(parsed) == 0 {
		return fmt.Errorf("jwks at %s contained no usable RSA keys", c.url)
	}

	c.mu.Lock()
	c.keys = parsed
	c.fetchedAt = time.Now()
	c.mu.Unlock()
	return nil
}

// Warm does an initial fetch so startup fails loudly on a bad JWKS URL rather
// than on the first request that needs it.
func (c *Cache) Warm() error { return c.refresh() }

func parseRSA(k jwk) (*rsa.PublicKey, error) {
	nb, err := b64(k.N)
	if err != nil {
		return nil, fmt.Errorf("modulus: %w", err)
	}
	eb, err := b64(k.E)
	if err != nil {
		return nil, fmt.Errorf("exponent: %w", err)
	}

	e := 0
	for _, b := range eb {
		e = e<<8 | int(b)
	}
	if e == 0 {
		return nil, fmt.Errorf("zero exponent")
	}

	return &rsa.PublicKey{N: new(big.Int).SetBytes(nb), E: e}, nil
}

// JWK mandates unpadded base64url, but tolerate padded input too.
func b64(s string) ([]byte, error) {
	if b, err := base64.RawURLEncoding.DecodeString(s); err == nil {
		return b, nil
	}
	return base64.URLEncoding.DecodeString(s)
}
