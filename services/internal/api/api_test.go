package api

import (
	"encoding/json"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/pe-workflow/services/internal/auth"
	"github.com/pe-workflow/services/internal/proxy"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"testing/fstest"

	"golang.org/x/oauth2/clientcredentials"
)

func TestRouterHealthAndSPAFallback(t *testing.T) {
	p, err := proxy.NewClient("http://127.0.0.1:1", auth.NewTokenManager(clientcredentials.Config{TokenURL: "http://127.0.0.1:1", ClientID: "id", ClientSecret: "secret"}), nil)
	if err != nil {
		t.Fatal(err)
	}
	static := fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("<app-root></app-root>")}, "assets/app.js": &fstest.MapFile{Data: []byte("app")}}
	reg := prometheus.NewRegistry()
	h := NewRouter(p, static, slog.Default(), NewMetrics(reg))
	for _, tc := range []struct{ path, want string }{{"/healthz", `{"status":"ok"}`}, {"/process/42", "<app-root></app-root>"}, {"/assets/app.js", "app"}} {
		r := httptest.NewRecorder()
		h.ServeHTTP(r, httptest.NewRequest(http.MethodGet, tc.path, nil))
		if r.Code != http.StatusOK || r.Body.String() != tc.want+func() string {
			if tc.path == "/healthz" {
				return "\n"
			}
			return ""
		}() {
			t.Fatalf("%s: status=%d body=%q", tc.path, r.Code, r.Body.String())
		}
	}
	var _ fs.FS = static
}

func TestRouterUsesRESTV2PathsAndWrapsXML(t *testing.T) {
	tokenServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"token","token_type":"Bearer","expires_in":3600}`))
	}))
	defer tokenServer.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v2/process-instances/42/sequence-flows":
			if r.Method != http.MethodGet {
				t.Fatal(r.Method)
			}
			_, _ = w.Write([]byte(`{"items":[]}`))
		case "/v2/variables/search":
			body, _ := io.ReadAll(r.Body)
			var payload map[string]any
			if err := json.Unmarshal(body, &payload); err != nil {
				t.Fatal(err)
			}
			filter := payload["filter"].(map[string]any)
			if filter["processInstanceKey"] != "42" || filter["name"] != "status" {
				t.Fatalf("filter=%v", filter)
			}
			_, _ = w.Write([]byte(`{"items":[]}`))
		case "/v2/process-definitions/7/xml":
			w.Header().Set("Content-Type", "application/xml")
			_, _ = w.Write([]byte(`<definitions />`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	manager := auth.NewTokenManager(clientcredentials.Config{TokenURL: tokenServer.URL, ClientID: "id", ClientSecret: "secret"})
	client, err := proxy.NewClient(upstream.URL, manager, upstream.Client())
	if err != nil {
		t.Fatal(err)
	}
	static := fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("ok")}}
	h := NewRouter(client, static, slog.Default(), NewMetrics(prometheus.NewRegistry()))

	variableRequest := httptest.NewRequest(http.MethodPost, "/api/process-instances/42/variables", strings.NewReader(`{"filter":{"name":"status"},"page":{"limit":10}}`))
	variableRequest.Header.Set("Content-Type", "application/json")
	for _, req := range []*http.Request{
		httptest.NewRequest(http.MethodGet, "/api/process-instances/42/sequences", nil),
		variableRequest,
	} {
		recorder := httptest.NewRecorder()
		h.ServeHTTP(recorder, req)
		if recorder.Code != http.StatusOK {
			t.Fatalf("path=%s status=%d body=%s", req.URL.Path, recorder.Code, recorder.Body.String())
		}
	}
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/process-definitions/7/xml", nil))
	var xmlResponse map[string]string
	if err := json.Unmarshal(recorder.Body.Bytes(), &xmlResponse); err != nil {
		t.Fatal(err)
	}
	if recorder.Code != http.StatusOK || recorder.Header().Get("Content-Type") != "application/json" || xmlResponse["xml"] != "<definitions />" {
		t.Fatalf("xml status=%d content-type=%q body=%q", recorder.Code, recorder.Header().Get("Content-Type"), recorder.Body.String())
	}
}

func TestMiddlewarePanicRecovery(t *testing.T) {
	t.Run("before any write", func(t *testing.T) {
		reg := prometheus.NewRegistry()
		s := &Server{logger: slog.New(slog.NewTextHandler(io.Discard, nil)), metrics: NewMetrics(reg)}
		handler := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			panic("boom")
		}))
		rw := httptest.NewRecorder()
		handler.ServeHTTP(rw, httptest.NewRequest(http.MethodGet, "/api/test", nil))
		if rw.Code != http.StatusInternalServerError {
			t.Fatalf("status=%d body=%s", rw.Code, rw.Body.String())
		}
		var body map[string]string
		if err := json.Unmarshal(rw.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if body["code"] != "internal" {
			t.Fatalf("body=%v", body)
		}
		if got := testutil.ToFloat64(s.metrics.Requests.WithLabelValues(http.MethodGet, "/api/test", "500")); got != 1 {
			t.Fatalf("500 metric=%v, want 1", got)
		}
		if got := testutil.ToFloat64(s.metrics.Requests.WithLabelValues(http.MethodGet, "/api/test", "200")); got != 0 {
			t.Fatalf("200 metric=%v, want 0", got)
		}
	})

	t.Run("after partial write", func(t *testing.T) {
		reg := prometheus.NewRegistry()
		s := &Server{logger: slog.New(slog.NewTextHandler(io.Discard, nil)), metrics: NewMetrics(reg)}
		handler := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte("partial"))
			panic("boom")
		}))
		rw := httptest.NewRecorder()
		handler.ServeHTTP(rw, httptest.NewRequest(http.MethodGet, "/api/partial", nil))
		if rw.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rw.Code, rw.Body.String())
		}
		if rw.Body.String() != "partial" {
			t.Fatalf("body=%q, want %q (no malformed 500 appended)", rw.Body.String(), "partial")
		}
		if got := testutil.ToFloat64(s.metrics.Requests.WithLabelValues(http.MethodGet, "/api/partial", "500")); got != 0 {
			t.Fatalf("500 metric=%v, want 1", got)
		}
		if got := testutil.ToFloat64(s.metrics.Requests.WithLabelValues(http.MethodGet, "/api/partial", "200")); got != 1 {
			t.Fatalf("200 metric=%v, want 1", got)
		}
	})
}
