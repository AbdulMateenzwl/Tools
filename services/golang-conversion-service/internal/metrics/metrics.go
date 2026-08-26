// Package metrics holds the Prometheus collectors for this service and the Gin
// middleware that feeds them.
//
// Collectors are package-level and registered against the default registry at
// init, which is the idiomatic client_golang pattern: the alternative — passing
// a registry through every layer — would mean changing the signature of every
// handler constructor for no practical gain, since there is exactly one process
// and one registry.
package metrics

import (
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// metricsPath is skipped by the middleware so scrapes do not inflate the very
// counters they are reporting.
const metricsPath = "/metrics"

// unmatchedRoute is the label used for requests that matched no route. Gin
// returns "" from FullPath() for a 404, and labelling those with the raw URL
// would let any caller mint unbounded label values by hitting random paths —
// the classic way to blow up a Prometheus server's memory. Every 404 therefore
// collapses into this single series.
const unmatchedRoute = "unmatched"

var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "convertx",
		Name:      "http_requests_total",
		Help:      "Total HTTP requests by method, matched route and status code.",
	}, []string{"method", "route", "status"})

	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "convertx",
		Name:      "http_request_duration_seconds",
		Help:      "End-to-end HTTP request latency, including cache lookups.",
		Buckets:   prometheus.DefBuckets,
	}, []string{"method", "route"})

	httpInFlight = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "convertx",
		Name:      "http_requests_in_flight",
		Help:      "HTTP requests currently being served.",
	})

	cacheOps = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "convertx",
		Name:      "conversion_cache_operations_total",
		Help:      "Conversion cache lookups by operation and outcome (hit/miss).",
	}, []string{"operation", "result"})

	conversions = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "convertx",
		Name:      "conversions_total",
		Help:      "Conversions actually executed (cache misses only) by outcome.",
	}, []string{"operation", "result"})

	// Separate from http_request_duration_seconds on purpose: this measures the
	// converter function alone, so a latency regression can be attributed to the
	// conversion itself rather than to Redis or request handling. Buckets start
	// far lower than DefBuckets because these are in-process string transforms,
	// not network calls.
	conversionDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "convertx",
		Name:      "conversion_duration_seconds",
		Help:      "Time spent inside the converter function, excluding cache hits.",
		Buckets:   []float64{.0001, .00025, .0005, .001, .0025, .005, .01, .025, .05, .1, .25, .5, 1},
	}, []string{"operation"})

	// Kong and the auth service both cap request bodies at 1MB; the top bucket
	// sits at that cap so a rise in near-limit payloads is visible before
	// callers start getting 413s.
	inputBytes = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "convertx",
		Name:      "conversion_input_bytes",
		Help:      "Size of conversion input payloads in bytes.",
		Buckets:   prometheus.ExponentialBuckets(64, 4, 8),
	}, []string{"operation"})
)

// Middleware records RED metrics for every request.
//
// Register it as the OUTERMOST middleware, ahead of gin.Recovery: the status
// code is read in a deferred call, so Recovery must have already run and set
// its 500 by then, otherwise a panicking handler would be recorded as a 200.
func Middleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.Request.URL.Path == metricsPath {
			c.Next()
			return
		}

		route := c.FullPath()
		if route == "" {
			route = unmatchedRoute
		}

		start := time.Now()
		httpInFlight.Inc()

		// Deferred so that a panic unwinding through here is still counted and
		// still decrements the gauge, rather than leaking it upwards forever.
		defer func() {
			httpInFlight.Dec()
			status := strconv.Itoa(c.Writer.Status())
			httpRequests.WithLabelValues(c.Request.Method, route, status).Inc()
			httpDuration.WithLabelValues(c.Request.Method, route).Observe(time.Since(start).Seconds())
		}()

		c.Next()
	}
}

// Handler serves the Prometheus exposition format, including the Go runtime and
// process collectors that promauto's default registry provides for free.
func Handler() gin.HandlerFunc {
	h := promhttp.Handler()
	return func(c *gin.Context) { h.ServeHTTP(c.Writer, c.Request) }
}

// RecordCacheResult records a cache lookup. Hit rate per operation is the whole
// point of the cache, and nothing else in the stack can observe it.
func RecordCacheResult(operation string, hit bool) {
	result := "miss"
	if hit {
		result = "hit"
	}
	cacheOps.WithLabelValues(operation, result).Inc()
}

// RecordConversion records one executed conversion and how long it took.
func RecordConversion(operation string, err error, elapsed time.Duration) {
	result := "success"
	if err != nil {
		result = "error"
	}
	conversions.WithLabelValues(operation, result).Inc()
	conversionDuration.WithLabelValues(operation).Observe(elapsed.Seconds())
}

// RecordInputSize records the payload size handed to a conversion.
func RecordInputSize(operation string, n int) {
	inputBytes.WithLabelValues(operation).Observe(float64(n))
}
