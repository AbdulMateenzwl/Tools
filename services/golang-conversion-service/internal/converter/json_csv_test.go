package converter

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestJSONToCSV(t *testing.T) {
	t.Run("headers are sorted for stable output", func(t *testing.T) {
		// Keys deliberately out of alphabetical order in the input.
		got, err := JSONToCSV(`[{"name":"John","age":"30","city":"Dublin"}]`)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		header := strings.Split(strings.TrimSpace(got), "\n")[0]
		if header != "age,city,name" {
			t.Errorf("header = %q, want %q", header, "age,city,name")
		}
	})

	t.Run("records with missing keys get empty cells", func(t *testing.T) {
		got, err := JSONToCSV(`[{"a":"1","b":"2"},{"a":"3"}]`)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		lines := strings.Split(strings.TrimSpace(got), "\n")
		if len(lines) != 3 {
			t.Fatalf("expected header + 2 rows, got %d lines: %q", len(lines), got)
		}
		if lines[2] != "3," {
			t.Errorf("row with missing key = %q, want %q", lines[2], "3,")
		}
	})

	t.Run("values containing commas are quoted", func(t *testing.T) {
		got, err := JSONToCSV(`[{"note":"a,b"}]`)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if !strings.Contains(got, `"a,b"`) {
			t.Errorf("comma value not quoted: %q", got)
		}
	})

	t.Run("errors", func(t *testing.T) {
		for name, input := range map[string]string{
			"empty array":  `[]`,
			"not an array": `{"a":"1"}`,
			"malformed":    `[{`,
		} {
			if _, err := JSONToCSV(input); err == nil {
				t.Errorf("%s: expected error", name)
			}
		}
	})
}

func TestCSVToJSON(t *testing.T) {
	t.Run("maps header row onto values", func(t *testing.T) {
		got, err := CSVToJSON("name,age\nJohn,30\nJane,25")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		var records []map[string]interface{}
		if err := json.Unmarshal([]byte(got), &records); err != nil {
			t.Fatalf("output is not valid JSON: %v", err)
		}
		if len(records) != 2 {
			t.Fatalf("got %d records, want 2", len(records))
		}
		if records[0]["name"] != "John" || records[1]["age"] != "25" {
			t.Errorf("unexpected records: %s", got)
		}
	})

	t.Run("header only is rejected", func(t *testing.T) {
		if _, err := CSVToJSON("name,age"); err == nil {
			t.Error("expected error for header-only CSV")
		}
	})

	t.Run("empty input is rejected", func(t *testing.T) {
		if _, err := CSVToJSON(""); err == nil {
			t.Error("expected error for empty CSV")
		}
	})
}

func TestCSVRoundTrip(t *testing.T) {
	original := "age,name\n30,John\n25,Jane"

	asJSON, err := CSVToJSON(original)
	if err != nil {
		t.Fatalf("to json: %v", err)
	}
	back, err := JSONToCSV(asJSON)
	if err != nil {
		t.Fatalf("back to csv: %v", err)
	}

	if strings.TrimSpace(back) != original {
		t.Errorf("round trip changed data:\n got: %q\nwant: %q", strings.TrimSpace(back), original)
	}
}
