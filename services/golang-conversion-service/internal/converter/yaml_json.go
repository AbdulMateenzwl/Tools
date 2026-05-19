package converter

import (
    "encoding/json"
    "fmt"

    "github.com/goccy/go-yaml"
)

// YAMLToJSON converts a YAML string to pretty-printed JSON
func YAMLToJSON(input string) (string, error) {
    var data interface{}
    if err := yaml.Unmarshal([]byte(input), &data); err != nil {
        return "", fmt.Errorf("invalid YAML: %w", err)
    }

    out, err := json.MarshalIndent(data, "", "  ")
    if err != nil {
        return "", fmt.Errorf("marshal JSON: %w", err)
    }

    return string(out), nil
}

// JSONToYAML converts a JSON string to YAML
func JSONToYAML(input string) (string, error) {
    var data interface{}
    if err := json.Unmarshal([]byte(input), &data); err != nil {
        return "", fmt.Errorf("invalid JSON: %w", err)
    }

    out, err := yaml.Marshal(data)
    if err != nil {
        return "", fmt.Errorf("marshal YAML: %w", err)
    }

    return string(out), nil
}