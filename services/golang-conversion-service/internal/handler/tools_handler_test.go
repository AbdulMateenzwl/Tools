package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"testing"

	"github.com/gin-gonic/gin"
)

func newToolsRouter() *gin.Engine {
	h := NewToolsHandler()
	r := gin.New()
	g := r.Group("/api/v1/tools")
	g.POST("/base64/encode", h.Base64Encode)
	g.POST("/base64/decode", h.Base64Decode)
	g.POST("/url/encode", h.URLEncode)
	g.POST("/url/decode", h.URLDecode)
	g.POST("/jwt/decode", h.JWTDecode)
	g.GET("/uuid", h.GenerateUUID)
	r.GET("/health", h.Health)
	return r
}

func get(t *testing.T, r *gin.Engine, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	return w
}

func TestBase64(t *testing.T) {
	r := newToolsRouter()

	t.Run("encode", func(t *testing.T) {
		w := post(t, r, "/api/v1/tools/base64/encode", `{"input":"Hello ConvertX"}`)
		if got := decode(t, w).Output; got != "SGVsbG8gQ29udmVydFg=" {
			t.Errorf("output = %q", got)
		}
	})

	t.Run("decode", func(t *testing.T) {
		w := post(t, r, "/api/v1/tools/base64/decode", `{"input":"SGVsbG8gQ29udmVydFg="}`)
		if got := decode(t, w).Output; got != "Hello ConvertX" {
			t.Errorf("output = %q", got)
		}
	})

	t.Run("decode falls back to URL-safe alphabet", func(t *testing.T) {
		// "??>>" in standard base64 is "Pz8-Pg==" URL-safe; standard decoding
		// of it fails, so this exercises the fallback branch.
		w := post(t, r, "/api/v1/tools/base64/decode", `{"input":"Pz8-Pg=="}`)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200 (body: %s)", w.Code, w.Body.String())
		}
		if got := decode(t, w).Output; got != "??>>" {
			t.Errorf("output = %q, want %q", got, "??>>")
		}
	})

	t.Run("decode rejects garbage", func(t *testing.T) {
		w := post(t, r, "/api/v1/tools/base64/decode", `{"input":"!!!notbase64!!!"}`)
		if w.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", w.Code)
		}
	})
}

func TestURLEncoding(t *testing.T) {
	r := newToolsRouter()

	t.Run("round trip", func(t *testing.T) {
		original := "https://convertx.io?type=json&output=xml"

		enc := decode(t, postInput(t, r, "/api/v1/tools/url/encode", original)).Output
		got := decode(t, postInput(t, r, "/api/v1/tools/url/decode", enc)).Output

		if got != original {
			t.Errorf("round trip = %q, want %q", got, original)
		}
	})

	t.Run("decode rejects a bad escape", func(t *testing.T) {
		w := post(t, r, "/api/v1/tools/url/decode", `{"input":"%zz"}`)
		if w.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", w.Code)
		}
	})
}

func TestJWTDecode(t *testing.T) {
	r := newToolsRouter()

	// Static unsigned-payload token: {"alg":"HS256","typ":"JWT"} /
	// {"sub":"1234567890","name":"John Doe"}
	const token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
		"eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIn0." +
		"dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"

	t.Run("decodes header and payload", func(t *testing.T) {
		w := post(t, r, "/api/v1/tools/jwt/decode", `{"input":"`+token+`"}`)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d (body: %s)", w.Code, w.Body.String())
		}

		var body struct {
			Header  map[string]interface{} `json:"header"`
			Payload map[string]interface{} `json:"payload"`
			Valid   bool                   `json:"signature_valid"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("invalid JSON: %v", err)
		}
		if body.Header["alg"] != "HS256" {
			t.Errorf("alg = %v, want HS256", body.Header["alg"])
		}
		if body.Payload["name"] != "John Doe" {
			t.Errorf("name = %v, want John Doe", body.Payload["name"])
		}
		// The endpoint never verifies signatures; it must not claim otherwise.
		if body.Valid {
			t.Error("signature_valid should always be false")
		}
	})

	t.Run("rejects a non-JWT", func(t *testing.T) {
		w := post(t, r, "/api/v1/tools/jwt/decode", `{"input":"not.a.jwt"}`)
		if w.Code != http.StatusBadRequest {
			t.Errorf("status = %d, want 400", w.Code)
		}
	})
}

func TestGenerateUUID(t *testing.T) {
	r := newToolsRouter()
	v4 := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

	seen := map[string]bool{}
	for i := 0; i < 50; i++ {
		var body struct {
			UUID string `json:"uuid"`
		}
		w := get(t, r, "/api/v1/tools/uuid")
		if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
			t.Fatalf("invalid JSON: %v", err)
		}
		if !v4.MatchString(body.UUID) {
			t.Fatalf("not a v4 UUID: %q", body.UUID)
		}
		if seen[body.UUID] {
			t.Fatalf("duplicate UUID returned: %q", body.UUID)
		}
		seen[body.UUID] = true
	}
}

func TestHealth(t *testing.T) {
	w := get(t, newToolsRouter(), "/health")
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
}
