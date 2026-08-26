package metrics

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func init() { gin.SetMode(gin.TestMode) }

// get drives one request through a router and returns the recorder.
func get(t *testing.T, r *gin.Engine, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	return w
}

// Collectors are package-level, so tests observe a shared registry and must
// compare deltas rather than absolute values.
func requestCount(t *testing.T, method, route, status string) float64 {
	t.Helper()
	return testutil.ToFloat64(httpRequests.WithLabelValues(method, route, status))
}

func TestMiddlewareLabelsByRouteTemplate(t *testing.T) {
	r := gin.New()
	r.Use(Middleware())
	r.GET("/thing/:id", func(c *gin.Context) { c.Status(http.StatusOK) })

	before := requestCount(t, "GET", "/thing/:id", "200")
	get(t, r, "/thing/abc")
	get(t, r, "/thing/def")

	if got := requestCount(t, "GET", "/thing/:id", "200") - before; got != 2 {
		t.Errorf("route-template counter delta = %v, want 2", got)
	}
	// The whole point of the template: distinct IDs must not mint new series.
	if n := requestCount(t, "GET", "/thing/abc", "200"); n != 0 {
		t.Errorf("raw path minted a series with count %v, want 0", n)
	}
}

func TestMiddlewareCollapsesUnmatchedRoutes(t *testing.T) {
	r := gin.New()
	r.Use(Middleware())
	r.GET("/known", func(c *gin.Context) { c.Status(http.StatusOK) })

	before := requestCount(t, "GET", unmatchedRoute, "404")
	get(t, r, "/nope/one")
	get(t, r, "/nope/two")

	if got := requestCount(t, "GET", unmatchedRoute, "404") - before; got != 2 {
		t.Errorf("unmatched counter delta = %v, want 2", got)
	}
	if n := requestCount(t, "GET", "/nope/one", "404"); n != 0 {
		t.Errorf("unmatched path minted its own series (count %v), want 0", n)
	}
}

func TestMiddlewareSkipsMetricsPath(t *testing.T) {
	r := gin.New()
	r.Use(Middleware())
	r.GET(metricsPath, Handler())

	before := requestCount(t, "GET", metricsPath, "200")
	w := get(t, r, metricsPath)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}
	if got := requestCount(t, "GET", metricsPath, "200") - before; got != 0 {
		t.Errorf("scrape was counted (delta %v), want 0", got)
	}
	if !strings.Contains(w.Body.String(), "convertx_http_requests_total") {
		t.Error("exposition output missing convertx_http_requests_total")
	}
}

// Recovery runs inside the metrics middleware, so a panicking handler must be
// recorded as the 500 the client actually received.
func TestMiddlewareRecordsPanicAs500(t *testing.T) {
	r := gin.New()
	r.Use(Middleware())
	r.Use(gin.Recovery())
	r.GET("/boom", func(c *gin.Context) { panic("kaboom") })

	before := requestCount(t, "GET", "/boom", "500")
	get(t, r, "/boom")

	if got := requestCount(t, "GET", "/boom", "500") - before; got != 1 {
		t.Errorf("panic counter delta = %v, want 1", got)
	}
	if n := testutil.ToFloat64(httpInFlight); n != 0 {
		t.Errorf("in-flight gauge leaked after panic: %v, want 0", n)
	}
}

func TestRecordCacheResult(t *testing.T) {
	hitBefore := testutil.ToFloat64(cacheOps.WithLabelValues("json-to-xml", "hit"))
	missBefore := testutil.ToFloat64(cacheOps.WithLabelValues("json-to-xml", "miss"))

	RecordCacheResult("json-to-xml", true)
	RecordCacheResult("json-to-xml", false)
	RecordCacheResult("json-to-xml", false)

	if got := testutil.ToFloat64(cacheOps.WithLabelValues("json-to-xml", "hit")) - hitBefore; got != 1 {
		t.Errorf("hit delta = %v, want 1", got)
	}
	if got := testutil.ToFloat64(cacheOps.WithLabelValues("json-to-xml", "miss")) - missBefore; got != 2 {
		t.Errorf("miss delta = %v, want 2", got)
	}
}

func TestRecordConversionSplitsOnError(t *testing.T) {
	okBefore := testutil.ToFloat64(conversions.WithLabelValues("csv-to-json", "success"))
	errBefore := testutil.ToFloat64(conversions.WithLabelValues("csv-to-json", "error"))

	RecordConversion("csv-to-json", nil, 0)
	RecordConversion("csv-to-json", http.ErrBodyNotAllowed, 0)

	if got := testutil.ToFloat64(conversions.WithLabelValues("csv-to-json", "success")) - okBefore; got != 1 {
		t.Errorf("success delta = %v, want 1", got)
	}
	if got := testutil.ToFloat64(conversions.WithLabelValues("csv-to-json", "error")) - errBefore; got != 1 {
		t.Errorf("error delta = %v, want 1", got)
	}
}
