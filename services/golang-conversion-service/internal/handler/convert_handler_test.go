package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/convertx/golang-conversion-service/internal/cache"
	"github.com/gin-gonic/gin"
)

func init() { gin.SetMode(gin.TestMode) }

// newConvertRouter wires the convert routes against an in-memory cache, which
// is what lets these run with no Redis.
func newConvertRouter() *gin.Engine {
	h := NewConvertHandler(cache.NewMemoryCache())
	r := gin.New()
	g := r.Group("/api/v1/convert")
	g.POST("/json-to-xml", h.JSONToXML)
	g.POST("/xml-to-json", h.XMLToJSON)
	g.POST("/json-to-csv", h.JSONToCSV)
	g.POST("/csv-to-json", h.CSVToJSON)
	g.POST("/yaml-to-json", h.YAMLToJSON)
	g.POST("/json-to-yaml", h.JSONToYAML)
	return r
}

// post sends a JSON body and returns the recorder.
func post(t *testing.T, r *gin.Engine, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

type convertBody struct {
	Output string `json:"output"`
	Cached bool   `json:"cached"`
	Error  string `json:"error"`
}

func decode(t *testing.T, w *httptest.ResponseRecorder) convertBody {
	t.Helper()
	var body convertBody
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not valid JSON: %v\nbody: %s", err, w.Body.String())
	}
	return body
}

func TestConvertEndpoints(t *testing.T) {
	r := newConvertRouter()

	tests := []struct {
		name     string
		path     string
		input    string
		contains string
	}{
		{"json to xml", "/api/v1/convert/json-to-xml", `{\"name\":\"John\"}`, "<name>John</name>"},
		{"xml to json", "/api/v1/convert/xml-to-json", `<p><name>John</name></p>`, "John"},
		{"json to csv", "/api/v1/convert/json-to-csv", `[{\"a\":\"1\"}]`, "a"},
		{"csv to json", "/api/v1/convert/csv-to-json", `a,b\nc,d`, "c"},
		{"yaml to json", "/api/v1/convert/yaml-to-json", `name: John`, "John"},
		{"json to yaml", "/api/v1/convert/json-to-yaml", `{\"name\":\"John\"}`, "name: John"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			w := post(t, r, tt.path, `{"input":"`+tt.input+`"}`)
			if w.Code != http.StatusOK {
				t.Fatalf("status = %d, want 200\nbody: %s", w.Code, w.Body.String())
			}
			body := decode(t, w)
			if !strings.Contains(body.Output, tt.contains) {
				t.Errorf("output missing %q\ngot: %s", tt.contains, body.Output)
			}
		})
	}
}

func TestConvertCaching(t *testing.T) {
	r := newConvertRouter()
	payload := `{"input":"{\"cacheme\":true}"}`

	first := decode(t, post(t, r, "/api/v1/convert/json-to-xml", payload))
	if first.Cached {
		t.Error("first request reported cached=true")
	}

	second := decode(t, post(t, r, "/api/v1/convert/json-to-xml", payload))
	if !second.Cached {
		t.Error("second identical request reported cached=false")
	}
	if first.Output != second.Output {
		t.Errorf("cached output differs:\n first: %s\nsecond: %s", first.Output, second.Output)
	}
}

func TestConvertCacheIsKeyedPerOperation(t *testing.T) {
	r := newConvertRouter()
	// Same input string, two different endpoints: the second must not be
	// served the first one's cached result.
	payload := `{"input":"{\"a\":\"1\"}"}`

	post(t, r, "/api/v1/convert/json-to-xml", payload)
	second := decode(t, post(t, r, "/api/v1/convert/json-to-yaml", payload))

	if second.Cached {
		t.Error("a different operation was served from the first operation's cache entry")
	}
}

func TestConvertBadRequests(t *testing.T) {
	r := newConvertRouter()

	t.Run("missing input field", func(t *testing.T) {
		w := post(t, r, "/api/v1/convert/json-to-xml", `{}`)
		if w.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", w.Code)
		}
	})

	t.Run("malformed request body", func(t *testing.T) {
		w := post(t, r, "/api/v1/convert/json-to-xml", `not json`)
		if w.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", w.Code)
		}
	})

	t.Run("valid request but unconvertible payload", func(t *testing.T) {
		w := post(t, r, "/api/v1/convert/json-to-xml", `{"input":"not json {{{"}`)
		if w.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", w.Code)
		}
		if decode(t, w).Error == "" {
			t.Error("expected an error message in the body")
		}
	})

	t.Run("failed conversions are not cached", func(t *testing.T) {
		bad := `{"input":"not json {{{"}`
		post(t, r, "/api/v1/convert/json-to-xml", bad)
		w := post(t, r, "/api/v1/convert/json-to-xml", bad)
		if w.Code != http.StatusBadRequest {
			t.Errorf("second attempt status = %d, want 400", w.Code)
		}
	})
}

// postInput marshals input into the standard {"input": ...} body, so callers
// do not have to hand-escape payloads containing quotes or percent signs.
func postInput(t *testing.T, r *gin.Engine, path, input string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(map[string]string{"input": input})
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	return post(t, r, path, string(body))
}
