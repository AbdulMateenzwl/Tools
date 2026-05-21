package converter

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/clbanning/mxj/v2"
)

func JSONToXML(input string) (string, error) {
	// Detect if input is an array
	trimmed := strings.TrimSpace(input)
	if strings.HasPrefix(trimmed, "[") {
		return jsonArrayToXML(input)
	}

	// Validate it is valid JSON object
	var raw map[string]interface{}
	if err := json.Unmarshal([]byte(input), &raw); err != nil {
		return "", fmt.Errorf("invalid JSON object: %w", err)
	}

	mv, err := mxj.NewMapJson([]byte(input))
	if err != nil {
		return "", fmt.Errorf("parse JSON: %w", err)
	}

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

// jsonArrayToXML handles root-level JSON arrays
// converts [{"name":"John"},{"name":"Jane"}]
// to <items><item><name>John</name></item><item><name>Jane</name></item></items>
func jsonArrayToXML(input string) (string, error) {
	var items []interface{}
	if err := json.Unmarshal([]byte(input), &items); err != nil {
		return "", fmt.Errorf("invalid JSON array: %w", err)
	}

	var sb strings.Builder
	sb.WriteString("<items>")

	for _, item := range items {
		itemBytes, err := json.Marshal(item)
		if err != nil {
			return "", fmt.Errorf("marshal array item: %w", err)
		}

		mv, err := mxj.NewMapJson(itemBytes)
		if err != nil {
			// item might be a primitive (string, number)
			sb.WriteString(fmt.Sprintf("<item>%v</item>", item))
			continue
		}

		xmlBytes, err := mv.XmlIndent("", "  ")
		if err != nil {
			return "", fmt.Errorf("convert item to XML: %w", err)
		}

		// mxj wraps in root element — strip it and use <item>
		xmlStr := string(xmlBytes)
		sb.WriteString("<item>")
		// extract inner content between first and last tag
		start := strings.Index(xmlStr, ">") + 1
		end := strings.LastIndex(xmlStr, "<")
		if start > 0 && end > start {
			sb.WriteString(xmlStr[start:end])
		}
		sb.WriteString("</item>")
	}

	sb.WriteString("</items>")
	return sb.String(), nil
}

func XMLToJSON(input string) (string, error) {
	input = strings.TrimSpace(input)
	if !strings.HasPrefix(input, "<") {
		return "", fmt.Errorf("invalid XML: must start with '<'")
	}

	mv, err := mxj.NewMapXml([]byte(input))
	if err != nil {
		return "", fmt.Errorf("parse XML: %w", err)
	}

	jsonBytes, err := mv.Json(true)
	if err != nil {
		return "", fmt.Errorf("convert to JSON: %w", err)
	}

	return string(jsonBytes), nil
}