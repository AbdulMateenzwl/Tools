package main

import (
	"context"
	"log"
	"os"

	"github.com/convertx/golang-conversion-service/internal/cache"
	"github.com/convertx/golang-conversion-service/internal/handler"
	"github.com/convertx/golang-conversion-service/internal/secrets"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
)

func main() {
	ctx := context.Background()

	// ── Load secrets from SecretsManager ──────────────────────
	log.Println("loading secrets from SecretsManager...")
	s, err := secrets.Load(ctx)
	if err != nil {
		log.Fatalf("load secrets: %v", err)
	}
	log.Println("secrets loaded successfully")

	// ── Redis ──────────────────────────────────────────────────
	rdb := redis.NewClient(&redis.Options{
		Addr:     s.RedisEndpoint,
		Password: s.RedisPassword,
	})
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Fatalf("connect to redis: %v", err)
	}
	log.Println("connected to redis")

	// ── Wire up layers ─────────────────────────────────────────
	redisCache := cache.NewRedisCache(rdb)
	convertHandler := handler.NewConvertHandler(redisCache)
	toolsHandler := handler.NewToolsHandler()

	r := gin.New()
	r.Use(gin.Logger())
	r.Use(gin.Recovery())

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