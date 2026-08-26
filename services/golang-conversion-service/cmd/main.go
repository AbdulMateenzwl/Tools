package main

import (
	"context"
	"log"
	"os"

	"github.com/convertx/golang-conversion-service/internal/cache"
	"github.com/convertx/golang-conversion-service/internal/handler"
	"github.com/convertx/golang-conversion-service/internal/metrics"
	"github.com/convertx/golang-conversion-service/internal/secrets"
	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"
)

func main() {
	ctx := context.Background()

	// Load ./.env if present, for local development. Deliberately tolerant and
	// non-overriding: there is no such file in the deployed image, and real
	// environment variables (K8s ConfigMaps) must always win over it.
	if err := godotenv.Load(); err == nil {
		log.Println("loaded configuration from .env")
	}

	// ── Wire up layers ─────────────────────────────────────────
	convertHandler := handler.NewConvertHandler(newCacheStore(ctx))
	toolsHandler := handler.NewToolsHandler()

	r := gin.New()
	// Metrics middleware goes first so it wraps Recovery: it reads the status
	// code in a deferred call, and Recovery must have set its 500 by then.
	r.Use(metrics.Middleware())
	r.Use(gin.Logger())
	r.Use(gin.Recovery())

	// Deliberately at the root rather than under /api/v1: the HTTPRoute only
	// forwards /api/v1/convert and /api/v1/tools, so this stays unreachable
	// through Kong and is scraped by Prometheus directly on the pod IP.
	r.GET("/metrics", metrics.Handler())

	v1 := r.Group("/api/v1")

	v1.GET("/convert/health", toolsHandler.Health)

	convert := v1.Group("/convert")
	{
		convert.POST("/json-to-xml",  convertHandler.JSONToXML)
		convert.POST("/xml-to-json",  convertHandler.XMLToJSON)
		convert.POST("/json-to-csv",  convertHandler.JSONToCSV)
		convert.POST("/csv-to-json",  convertHandler.CSVToJSON)
		convert.POST("/yaml-to-json", convertHandler.YAMLToJSON)
		convert.POST("/json-to-yaml", convertHandler.JSONToYAML)
	}

	tools := v1.Group("/tools")
	{
		tools.POST("/base64/encode", toolsHandler.Base64Encode)
		tools.POST("/base64/decode", toolsHandler.Base64Decode)
		tools.POST("/url/encode",    toolsHandler.URLEncode)
		tools.POST("/url/decode",    toolsHandler.URLDecode)
		tools.POST("/jwt/decode",    toolsHandler.JWTDecode)
		tools.GET("/uuid",           toolsHandler.GenerateUUID)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("conversion service starting on :%s", port)
	if err := r.Run(":" + port); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

// newCacheStore picks a cache backend from the environment. Conversions are
// pure functions, so the cache is this service's only dependency — which is
// what lets it run in three quite different setups:
//
//	AWS_ENDPOINT_URL set  -> deployed: endpoint and password from SecretsManager
//	REDIS_HOST set        -> docker-compose: a plain Redis, no AWS involved
//	neither               -> bare `go run ./cmd/main.go`: in-memory, no deps
func newCacheStore(ctx context.Context) cache.Store {
	switch {
	case os.Getenv("AWS_ENDPOINT_URL") != "":
		log.Println("loading secrets from SecretsManager...")
		s, err := secrets.Load(ctx)
		if err != nil {
			log.Fatalf("load secrets: %v", err)
		}
		log.Println("secrets loaded successfully")
		return connectRedis(ctx, s.RedisEndpoint, s.RedisPassword)

	case os.Getenv("REDIS_HOST") != "":
		// Deliberately skips SecretsManager: docker-compose supplies the
		// address and password directly, and there is no AWS to talk to.
		log.Printf("using redis at %s (no SecretsManager)", os.Getenv("REDIS_HOST"))
		return connectRedis(ctx, os.Getenv("REDIS_HOST"), os.Getenv("REDIS_PASSWORD"))

	default:
		log.Println("no cache backend configured - using in-memory cache (local dev)")
		return cache.NewMemoryCache()
	}
}

func connectRedis(ctx context.Context, addr, password string) cache.Store {
	rdb := redis.NewClient(&redis.Options{Addr: addr, Password: password})
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("connect to redis at %s: %v", addr, err)
	}
	log.Println("connected to redis")
	return cache.NewRedisCache(rdb)
}
