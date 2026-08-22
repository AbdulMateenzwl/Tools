package converter

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestYAMLToJSON(t *testing.T) {
	t.Run("whole numbers do not become floats", func(t *testing.T) {
		// This is what normalize() exists for: without it the YAML decoder
		// yields float64 and 30 marshals back out as 30.
		got, err := YAMLToJSON("name: John\nage: 30")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if strings.Contains(got, "30.0") {
			t.Errorf("whole number rendered as float: %s", got)
		}
		if !strings.Contains(got, `"age": 30`) {
			t.Errorf("expected `\"age\": 30` in output, got: %s", got)
		}
	})

	t.Run("genuine floats are preserved", func(t *testing.T) {
		got, err := YAMLToJSON("ratio: 1.5")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !strings.Contains(got, "1.5") {
			t.Errorf("float lost: %s", got)
		}
	})

	t.Run("nested maps and lists are normalized recursively", func(t *testing.T) {
		got, err := YAMLToJSON("user:\n  name: John\n  scores:\n    - 10\n    - 20\n")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		var parsed map[string]interface{}
		if err := json.Unmarshal([]byte(got), &parsed); err != nil {
			t.Fatalf("invalid JSON: %v\n%s", err, got)
		}
		user := parsed["user"].(map[string]interface{})
		if user["name"] != "John" {
			t.Errorf("nested name = %v", user["name"])
		}
		if strings.Contains(got, "10.0") || strings.Contains(got, "20.0") {
			t.Errorf("list values became floats: %s", got)
		}
	})

	t.Run("malformed yaml is rejected", func(t *testing.T) {
		if _, err := YAMLToJSON("key: [unclosed\n  bad: : :"); err == nil {
			t.Error("expected error for malformed YAML")
		}
	})
}

func TestJSONToYAML(t *testing.T) {
	got, err := JSONToYAML(`{"name":"John","age":30}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(got, "name: John") {
		t.Errorf("expected `name: John`, got: %s", got)
	}
	if !strings.Contains(got, "age: 30") {
		t.Errorf("expected `age: 30`, got: %s", got)
	}
}

func TestJSONToYAMLRejectsMalformed(t *testing.T) {
	if _, err := JSONToYAML(`not json {{{`); err == nil {
		t.Error("expected error for malformed JSON")
	}
}

func TestYAMLRoundTrip(t *testing.T) {
	original := `{"age":30,"name":"John"}`

	asYAML, err := JSONToYAML(original)
	if err != nil {
		t.Fatalf("to yaml: %v", err)
	}
	back, err := YAMLToJSON(asYAML)
	if err != nil {
		t.Fatalf("back to json: %v", err)
	}

	var got map[string]interface{}
	if err := json.Unmarshal([]byte(back), &got); err != nil {
		t.Fatalf("round trip produced invalid JSON: %v", err)
	}
	if got["name"] != "John" {
		t.Errorf("name lost in round trip: %s", back)
	}
	// json.Unmarshal gives float64 for any number, so compare numerically.
	if age, ok := got["age"].(float64); !ok || age != 30 {
		t.Errorf("age = %v (%T), want 30", got["age"], got["age"])
	}
}
