package converter

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestJSONToXML(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		wantParts []string
		wantErr   bool
	}{
		{
			name:      "single object",
			input:     `{"name":"John","age":30}`,
			wantParts: []string{"<name>John</name>", "<age>30</age>"},
		},
		{
			// Multi-key objects have no single root, so they get wrapped.
			name:      "object with multiple top level keys is wrapped in root",
			input:     `{"a":"1","b":"2"}`,
			wantParts: []string{"<root>", "</root>"},
		},
		{
			name:      "array becomes items/item",
			input:     `[{"name":"John"},{"name":"Jane"}]`,
			wantParts: []string{"<items>", "<item>", "John", "Jane", "</items>"},
		},
		{
			name:      "array with leading whitespace is still detected",
			input:     "  \n\t" + `[{"name":"John"}]`,
			wantParts: []string{"<items>"},
		},
		{name: "malformed json", input: `not json {{{`, wantErr: true},
		{name: "empty string", input: ``, wantErr: true},
		{name: "bare scalar is not an object", input: `"just a string"`, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := JSONToXML(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got output %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			for _, part := range tt.wantParts {
				if !strings.Contains(got, part) {
					t.Errorf("output missing %q\ngot: %s", part, got)
				}
			}
		})
	}
}

func TestXMLToJSON(t *testing.T) {
	got, err := XMLToJSON(`<person><name>John</name><age>30</age></person>`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(got), &parsed); err != nil {
		t.Fatalf("output is not valid JSON: %v\ngot: %s", err, got)
	}
	person, ok := parsed["person"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected a person object, got: %s", got)
	}
	if person["name"] != "John" {
		t.Errorf("name = %v, want John", person["name"])
	}
}

func TestXMLToJSONRejectsNonXML(t *testing.T) {
	for _, input := range []string{"", "   ", "name: John", `{"not":"xml"}`} {
		if _, err := XMLToJSON(input); err == nil {
			t.Errorf("expected error for %q", input)
		}
	}
}

func TestJSONToXMLRoundTrip(t *testing.T) {
	original := `{"person":{"name":"John","city":"Dublin"}}`

	xml, err := JSONToXML(original)
	if err != nil {
		t.Fatalf("to xml: %v", err)
	}
	back, err := XMLToJSON(xml)
	if err != nil {
		t.Fatalf("back to json: %v", err)
	}

	var got map[string]interface{}
	if err := json.Unmarshal([]byte(back), &got); err != nil {
		t.Fatalf("round trip produced invalid JSON: %v", err)
	}
	person := got["person"].(map[string]interface{})
	if person["name"] != "John" || person["city"] != "Dublin" {
		t.Errorf("round trip lost data: %s", back)
	}
}
