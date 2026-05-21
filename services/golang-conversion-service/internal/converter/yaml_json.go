package converter

import (
	"encoding/json"
	"fmt"

	"github.com/goccy/go-yaml"
)

func YAMLToJSON(input string) (string, error) {
	var data interface{}
	if err := yaml.Unmarshal([]byte(input), &data); err != nil {
		return "", fmt.Errorf("invalid YAML: %w", err)
	}

	// Normalize the data — converts go-yaml types to standard Go types
	// and fixes float64 whole numbers back to int64
	data = normalize(data)

	out, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshal JSON: %w", err)
	}

	return string(out), nil
}

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

// normalize recursively converts go-yaml internal types to
// standard Go types and fixes whole float64 → int64
func normalize(v interface{}) interface{} {
	switch val := v.(type) {
	case map[interface{}]interface{}:
		// go-yaml sometimes returns map[interface{}]interface{}
		result := map[string]interface{}{}
		for k, v2 := range val {
			result[fmt.Sprintf("%v", k)] = normalize(v2)
		}
		return result
	case map[string]interface{}:
		for k, v2 := range val {
			val[k] = normalize(v2)
		}
		return val
	case []interface{}:
		for i, v2 := range val {
			val[i] = normalize(v2)
		}
		return val
	case float64:
		// Convert whole numbers back to int so 30.0 → 30
		if val == float64(int64(val)) {
			return int64(val)
		}
		return val
	default:
		return v
	}
}