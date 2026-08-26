package handler

import (
    "net/http"
    "time"

    "github.com/convertx/golang-conversion-service/internal/cache"
    "github.com/convertx/golang-conversion-service/internal/converter"
    "github.com/convertx/golang-conversion-service/internal/metrics"
    "github.com/convertx/golang-conversion-service/internal/model"
    "github.com/gin-gonic/gin"
)

type ConvertHandler struct {
    cache cache.Store
}

// Takes the Store interface rather than *cache.RedisCache so handlers can be
// exercised in tests, and so the service can run against an in-memory cache.
func NewConvertHandler(cache cache.Store) *ConvertHandler {
    return &ConvertHandler{cache: cache}
}

// convert is a generic helper that wraps any converter function with caching
func (h *ConvertHandler) convert(
    c *gin.Context,
    operation string,
    fn func(string) (string, error),
) {
    var req model.ConvertRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "input is required"})
        return
    }

    metrics.RecordInputSize(operation, len(req.Input))

    // Check cache first
    key := cache.Key(operation, req.Input)
    if cached, ok := h.cache.Get(c.Request.Context(), key); ok {
        metrics.RecordCacheResult(operation, true)
        c.JSON(http.StatusOK, model.ConvertResponse{Output: cached, Cached: true})
        return
    }
    metrics.RecordCacheResult(operation, false)

    // Run conversion. Timed separately from the HTTP request so a slow
    // converter can be told apart from a slow Redis.
    start := time.Now()
    output, err := fn(req.Input)
    metrics.RecordConversion(operation, err, time.Since(start))
    if err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: err.Error()})
        return
    }

    // Store in cache
    h.cache.Set(c.Request.Context(), key, output)

    c.JSON(http.StatusOK, model.ConvertResponse{Output: output, Cached: false})
}

func (h *ConvertHandler) JSONToXML(c *gin.Context) {
    h.convert(c, "json-to-xml", converter.JSONToXML)
}

func (h *ConvertHandler) XMLToJSON(c *gin.Context) {
    h.convert(c, "xml-to-json", converter.XMLToJSON)
}

func (h *ConvertHandler) JSONToCSV(c *gin.Context) {
    h.convert(c, "json-to-csv", converter.JSONToCSV)
}

func (h *ConvertHandler) CSVToJSON(c *gin.Context) {
    h.convert(c, "csv-to-json", converter.CSVToJSON)
}

func (h *ConvertHandler) YAMLToJSON(c *gin.Context) {
    h.convert(c, "yaml-to-json", converter.YAMLToJSON)
}

func (h *ConvertHandler) JSONToYAML(c *gin.Context) {
    h.convert(c, "json-to-yaml", converter.JSONToYAML)
}