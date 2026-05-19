package converter

import (
    "encoding/json"
    "fmt"
    "strings"

    "github.com/clbanning/mxj/v2"
)

// JSONToXML converts a JSON string to XML
func JSONToXML(input string) (string, error) {
    // Validate it is valid JSON first
    var raw map[string]interface{}
    if err := json.Unmarshal([]byte(input), &raw); err != nil {
        return "", fmt.Errorf("invalid JSON: %w", err)
    }

    mv, err := mxj.NewMapJson([]byte(input))
    if err != nil {
        return "", fmt.Errorf("parse JSON: %w", err)
    }

    // mxj requires a single root element
    // wrap if the map has multiple top-level keys
    var xmlBytes []byte
    if len(mv) == 1 {
        xmlBytes, err = mv.Xml()
    } else {
        wrapped := mxj.Map{"root": map[string]interface{}(mv)}
        xmlBytes, err = wrapped.Xml()
    }
    if err != nil {
        return "", fmt.Errorf("convert to XML: %w", err)
    }

    return string(xmlBytes), nil
}

// XMLToJSON converts an XML string to JSON
func XMLToJSON(input string) (string, error) {
    input = strings.TrimSpace(input)
    if !strings.HasPrefix(input, "<") {
        return "", fmt.Errorf("invalid XML: must start with '<'")
    }

    mv, err := mxj.NewMapXml([]byte(input))
    if err != nil {
        return "", fmt.Errorf("parse XML: %w", err)
    }

    jsonBytes, err := mv.Json(true) // true = pretty print
    if err != nil {
        return "", fmt.Errorf("convert to JSON: %w", err)
    }

    return string(jsonBytes), nil
}