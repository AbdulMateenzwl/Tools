package handler

import (
    "net/http"

    "github.com/convertx/golang-conversion-service/internal/cache"
    "github.com/convertx/golang-conversion-service/internal/converter"
    "github.com/convertx/golang-conversion-service/internal/model"
    "github.com/gin-gonic/gin"
)

type ConvertHandler struct {
    cache *cache.RedisCache
}

func NewConvertHandler(cache *cache.RedisCache) *ConvertHandler {
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

    // Check cache first
    key := cache.Key(operation, req.Input)
    if cached, ok := h.cache.Get(c.Request.Context(), key); ok {
        c.JSON(http.StatusOK, model.ConvertResponse{Output: cached, Cached: true})
        return
    }

    // Run conversion
    output, err := fn(req.Input)
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