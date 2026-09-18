package api

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/pe-workflow/services/internal/proxy"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type apiError struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Metrics struct {
	Requests     *prometheus.CounterVec
	Latency      *prometheus.HistogramVec
	TokenRefresh prometheus.Counter
}

func NewMetrics(reg prometheus.Registerer) *Metrics {
	m := &Metrics{
		Requests:     prometheus.NewCounterVec(prometheus.CounterOpts{Name: "bff_proxy_requests_total", Help: "BFF proxy requests."}, []string{"method", "endpoint", "status"}),
		Latency:      prometheus.NewHistogramVec(prometheus.HistogramOpts{Name: "bff_proxy_latency_seconds", Help: "BFF proxy latency."}, []string{"method", "endpoint"}),
		TokenRefresh: prometheus.NewCounter(prometheus.CounterOpts{Name: "bff_token_refresh_total", Help: "Forced token refreshes."}),
	}
	reg.MustRegister(m.Requests, m.Latency, m.TokenRefresh)
	return m
}

type Server struct {
	proxy   *proxy.Client
	static  fs.FS
	logger  *slog.Logger
	metrics *Metrics
}

func NewRouter(p *proxy.Client, static fs.FS, logger *slog.Logger, metrics *Metrics) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	if metrics == nil {
		metrics = NewMetrics(prometheus.DefaultRegisterer)
	}
	s := &Server{proxy: p, static: static, logger: logger, metrics: metrics}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("POST /api/process-instances", s.forward("POST", "/v2/process-instances/search"))
	mux.HandleFunc("POST /api/process-instances/start", s.forward("POST", "/v2/process-instances"))
	mux.HandleFunc("GET /api/process-instances/{key}", s.forwardPath("GET", "/v2/process-instances/", "key"))
	mux.HandleFunc("GET /api/process-instances/{key}/sequences", s.forwardPath("GET", "/v2/process-instances/", "key", "/sequence-flows"))
	mux.HandleFunc("POST /api/process-instances/{key}/variables", s.searchVariables)
	mux.HandleFunc("POST /api/process-definitions", s.forward("POST", "/v2/process-definitions/search"))
	mux.HandleFunc("GET /api/process-definitions/{key}/xml", s.processXML)
	mux.HandleFunc("GET /api/process-definitions/{key}/form", s.forwardPath("GET", "/v2/process-definitions/", "key", "/form"))
	mux.HandleFunc("POST /api/user-tasks", s.forward("POST", "/v2/user-tasks/search"))
	mux.HandleFunc("GET /api/user-tasks/{key}/form", s.forwardPath("GET", "/v2/user-tasks/", "key", "/form"))
	mux.HandleFunc("POST /api/user-tasks/{key}/completion", s.forwardPath("POST", "/v2/user-tasks/", "key", "/completion"))
	mux.Handle("/", s.staticHandler())
	return s.middleware(mux)
}
func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, 200, map[string]string{"status": "ok"})
}
func (s *Server) searchVariables(w http.ResponseWriter, r *http.Request) {
	body, err := ioRead(r)
	if err != nil {
		s.fail(w, r, apiError{400, "bad_request", "invalid JSON body"})
		return
	}
	payload := map[string]any{}
	if len(bytes.TrimSpace(body)) > 0 {
		if err := json.Unmarshal(body, &payload); err != nil {
			s.fail(w, r, apiError{400, "bad_request", "invalid JSON body"})
			return
		}
	}
	filter, ok := payload["filter"].(map[string]any)
	if !ok {
		filter = map[string]any{}
	}
	filter["processInstanceKey"] = r.PathValue("key")
	payload["filter"] = filter
	body, err = json.Marshal(payload)
	if err != nil {
		s.fail(w, r, apiError{500, "internal", "internal server error"})
		return
	}
	s.proxyResponse(w, r, http.MethodPost, "/v2/variables/search", body)
}

func (s *Server) processXML(w http.ResponseWriter, r *http.Request) {
	resp, err := s.proxy.Do(r.Context(), http.MethodGet, "/v2/process-definitions/"+r.PathValue("key")+"/xml", nil)
	if err != nil {
		s.fail(w, r, mapUpstream(err))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		s.fail(w, r, mapStatus(resp.StatusCode, proxy.ReadError(resp)))
		return
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		s.fail(w, r, apiError{502, "upstream_error", "unable to read upstream response"})
		return
	}
	writeJSON(w, resp.StatusCode, map[string]string{"xml": string(data)})
}

func (s *Server) proxyResponse(w http.ResponseWriter, r *http.Request, method, path string, body []byte) {
	resp, err := s.proxy.Do(r.Context(), method, path, body)
	if err != nil {
		s.fail(w, r, mapUpstream(err))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		s.fail(w, r, mapStatus(resp.StatusCode, proxy.ReadError(resp)))
		return
	}
	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (s *Server) forward(method, target string) http.HandlerFunc {
	return s.doProxy(method, func(_ *http.Request) string { return target })
}
func (s *Server) forwardPath(method, prefix string, parts ...string) http.HandlerFunc {
	return s.doProxy(method, func(r *http.Request) string {
		p := prefix + r.PathValue(parts[0])
		for _, x := range parts[1:] {
			p += x
		}
		return p
	})
}
func (s *Server) doProxy(method string, target func(*http.Request) string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		b, err := ioRead(r)
		if err != nil {
			s.fail(w, r, apiError{400, "bad_request", "invalid JSON body"})
			return
		}
		resp, err := s.proxy.Do(r.Context(), method, target(r), b)
		if err != nil {
			s.fail(w, r, mapUpstream(err))
			return
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 400 {
			msg := proxy.ReadError(resp)
			s.fail(w, r, mapStatus(resp.StatusCode, msg))
			return
		}
		for k, v := range resp.Header {
			w.Header()[k] = v
		}
		w.WriteHeader(resp.StatusCode)
		_, _ = io.Copy(w, resp.Body)
	}
}
func ioRead(r *http.Request) ([]byte, error) {
	if r.Body == nil {
		return nil, nil
	}
	return io.ReadAll(r.Body)
}
func mapStatus(status int, msg string) apiError {
	switch status {
	case 400:
		if msg == "" {
			msg = "bad request"
		}
		return apiError{400, "bad_request", msg}
	case 401:
		return apiError{401, "unauthorized", "upstream authorization failed"}
	case 403:
		return apiError{403, "forbidden", "upstream access denied"}
	case 404:
		return apiError{404, "not_found", "resource not found"}
	default:
		return apiError{502, "upstream_error", "upstream request failed"}
	}
}
func mapUpstream(err error) apiError {
	var ue *proxy.UpstreamError
	if errors.As(err, &ue) {
		if ue.Status > 0 {
			return mapStatus(ue.Status, ue.Message)
		}
		if ue.Err != nil {
			var ne netError
			if errors.As(ue.Err, &ne) && ne.Timeout() {
				return apiError{504, "timeout", "upstream request timed out"}
			}
			return apiError{504, "timeout", "upstream unavailable"}
		}
	}
	return apiError{500, "internal", "internal server error"}
}

type netError interface{ Timeout() bool }

func (s *Server) fail(w http.ResponseWriter, r *http.Request, e apiError) { writeJSON(w, e.Status, e) }
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func (s *Server) staticHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			http.NotFound(w, r)
			return
		}
		p := strings.TrimPrefix(r.URL.Path, "/")
		data, index, err := s.readStatic(p)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if index || p == "" {
			w.Header().Set("Cache-Control", "no-cache")
		} else if strings.HasPrefix(r.URL.Path, "/assets/") {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}
		w.Header().Set("Content-Type", contentType(p, data))
		w.WriteHeader(200)
		_, _ = w.Write(data)
	})
}

// readStatic resolves a request path against the embedded static FS. It
// tolerates both a root-level layout (index.html at the FS root) and the
// //go:embed static/* layout (files under the static/ prefix), falling back
// to index.html for the SPA.
func (s *Server) readStatic(p string) ([]byte, bool, error) {
	for _, candidate := range []string{p, "static/" + p} {
		if data, err := fs.ReadFile(s.static, candidate); err == nil {
			return data, false, nil
		}
	}
	for _, candidate := range []string{"index.html", "static/index.html"} {
		if data, err := fs.ReadFile(s.static, candidate); err == nil {
			return data, true, nil
		}
	}
	return nil, false, fs.ErrNotExist
}
func contentType(p string, b []byte) string {
	if strings.HasSuffix(p, ".html") {
		return "text/html; charset=utf-8"
	}
	if strings.HasSuffix(p, ".js") {
		return "text/javascript; charset=utf-8"
	}
	if strings.HasSuffix(p, ".css") {
		return "text/css; charset=utf-8"
	}
	return http.DetectContentType(b)
}
func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if strings.HasPrefix(r.URL.Path, "/api/") && r.Method == "POST" {
			origin := r.Header.Get("Origin")
			if origin != "" && !allowedOrigin(origin) {
				writeJSON(w, 403, apiError{403, "forbidden", "origin not allowed"})
				return
			}
			if !strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
				writeJSON(w, 415, apiError{415, "bad_request", "Content-Type must be application/json"})
				return
			}
		}
		rw := &statusWriter{ResponseWriter: w}
		start := time.Now()
		defer func() {
			if x := recover(); x != nil {
				s.logger.Error("panic", "error", x)
				if rw.status == 0 {
					writeJSON(rw, 500, apiError{500, "internal", "internal server error"})
				}
			}
			status := rw.status
			if status == 0 {
				status = 200
			}
			s.metrics.Requests.WithLabelValues(r.Method, r.URL.Path, fmtStatus(status)).Inc()
			s.metrics.Latency.WithLabelValues(r.Method, r.URL.Path).Observe(time.Since(start).Seconds())
			s.logger.Info("request", "endpoint", r.URL.Path, "method", r.Method, "status", status, "request_id", requestID(r))
		}()
		next.ServeHTTP(rw, r)
	})
}
func allowedOrigin(o string) bool {
	for _, x := range []string{"http://localhost:8088", "http://localhost:4200", "http://127.0.0.1:8088", "http://127.0.0.1:4200"} {
		if o == x {
			return true
		}
	}
	return false
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(s int) { w.status = s; w.ResponseWriter.WriteHeader(s) }
func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = 200
	}
	return w.ResponseWriter.Write(b)
}
func requestID(r *http.Request) string {
	if x := r.Header.Get("X-Request-ID"); x != "" {
		return x
	}
	b := make([]byte, 8)
	if _, e := rand.Read(b); e == nil {
		return hex.EncodeToString(b)
	}
	return "unknown"
}
func fmtStatus(s int) string { return strconv.Itoa(s) }
