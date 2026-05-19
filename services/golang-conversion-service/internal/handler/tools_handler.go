package handler

import (
    "encoding/base64"
    "encoding/json"
    "net/http"
    "net/url"
    "strings"

    "github.com/convertx/golang-conversion-service/internal/model"
    "github.com/gin-gonic/gin"
    "github.com/golang-jwt/jwt/v5"
    "github.com/google/uuid"
)

type ToolsHandler struct{}

func NewToolsHandler() *ToolsHandler {
    return &ToolsHandler{}
}

func (h *ToolsHandler) Base64Encode(c *gin.Context) {
    var req model.ConvertRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "input is required"})
        return
    }
    encoded := base64.StdEncoding.EncodeToString([]byte(req.Input))
    c.JSON(http.StatusOK, model.ConvertResponse{Output: encoded})
}

func (h *ToolsHandler) Base64Decode(c *gin.Context) {
    var req model.ConvertRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "input is required"})
        return
    }
    decoded, err := base64.StdEncoding.DecodeString(req.Input)
    if err != nil {
        // try URL-safe base64 as fallback
        decoded, err = base64.URLEncoding.DecodeString(req.Input)
        if err != nil {
            c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "invalid base64 input"})
            return
        }
    }
    c.JSON(http.StatusOK, model.ConvertResponse{Output: string(decoded)})
}

func (h *ToolsHandler) URLEncode(c *gin.Context) {
    var req model.ConvertRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "input is required"})
        return
    }
    c.JSON(http.StatusOK, model.ConvertResponse{Output: url.QueryEscape(req.Input)})
}

func (h *ToolsHandler) URLDecode(c *gin.Context) {
    var req model.ConvertRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "input is required"})
        return
    }
    decoded, err := url.QueryUnescape(req.Input)
    if err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "invalid URL-encoded input"})
        return
    }
    c.JSON(http.StatusOK, model.ConvertResponse{Output: decoded})
}

func (h *ToolsHandler) JWTDecode(c *gin.Context) {
    var req model.ConvertRequest
    if err := c.ShouldBindJSON(&req); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "input is required"})
        return
    }

    // Parse without validation — we just want to decode the payload
    token, _, err := new(jwt.Parser).ParseUnverified(req.Input, jwt.MapClaims{})
    if err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "invalid JWT format"})
        return
    }

    // Decode header manually
    parts := strings.Split(req.Input, ".")
    if len(parts) != 3 {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "JWT must have 3 parts"})
        return
    }

    headerBytes, err := base64.RawURLEncoding.DecodeString(parts[0])
    if err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "invalid JWT header"})
        return
    }

    var header map[string]interface{}
    if err := json.Unmarshal(headerBytes, &header); err != nil {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "invalid JWT header JSON"})
        return
    }

    claims, ok := token.Claims.(jwt.MapClaims)
    if !ok {
        c.JSON(http.StatusBadRequest, model.ErrorResponse{Error: "invalid JWT claims"})
        return
    }

    c.JSON(http.StatusOK, model.JWTDecodeResponse{
        Header:  header,
        Payload: claims,
        Valid:   false, // we never verify signature here — that is intentional
    })
}

func (h *ToolsHandler) GenerateUUID(c *gin.Context) {
    c.JSON(http.StatusOK, gin.H{
        "uuid": uuid.New().String(),
    })
}

func (h *ToolsHandler) Health(c *gin.Context) {
    c.JSON(http.StatusOK, gin.H{"status": "ok"})
}