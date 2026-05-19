package model

// ConvertRequest is the standard input for all conversion endpoints
type ConvertRequest struct {
    Input string `json:"input" binding:"required"`
}

// ConvertResponse is the standard output for all conversion endpoints
type ConvertResponse struct {
    Output string `json:"output"`
    Cached bool   `json:"cached"`
}

// ErrorResponse is returned on any bad input
type ErrorResponse struct {
    Error string `json:"error"`
}

// JWTDecodeResponse holds decoded JWT parts
type JWTDecodeResponse struct {
    Header  map[string]interface{} `json:"header"`
    Payload map[string]interface{} `json:"payload"`
    Valid   bool                   `json:"signature_valid"`
}