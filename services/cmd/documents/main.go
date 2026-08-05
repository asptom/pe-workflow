package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
	"github.com/pe-workflow/services/internal/zeebeworker"
)

const port = ":8084"
const baseURL = "http://localhost:8084"

type documentRequest struct {
	DocumentationResult map[string]any `json:"documentationResult"`
	Provider            map[string]any `json:"provider"`
}

type documentResponse struct {
	DocumentID  string   `json:"documentId"`
	Format      string   `json:"format"`
	Sections    []string `json:"sections"`
	Pages       int      `json:"pages"`
	GeneratedAt string   `json:"generatedAt"`
}

func providerStr(provider map[string]any, key string) string {
	if v, ok := provider[key].(string); ok {
		return v
	}
	return ""
}

func handleGenerate(w http.ResponseWriter, r *http.Request) {
	var req documentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	sections := []string{}
	if raw, ok := req.DocumentationResult["requiredSections"].(string); ok {
		for _, s := range strings.Split(raw, ",") {
			if s = strings.TrimSpace(s); s != "" {
				sections = append(sections, s)
			}
		}
	}
	resp := documentResponse{
		DocumentID:  "DOC-" + providerStr(req.Provider, "npi") + "-" + strconv.FormatInt(time.Now().Unix(), 10),
		Format:      "PDF",
		Sections:    sections,
		Pages:       len(sections),
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
	}
	json.NewEncoder(w).Encode(resp)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /documents/generate", handleGenerate)

	srv := &http.Server{Addr: port, Handler: mux}
	go func() {
		log.Printf("documents-service listening on %s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	client, err := zeebeworker.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	worker := client.NewJobWorker().
		JobType("generate-doc").
		Handler(func(c worker.JobClient, j entities.Job) {
			zeebeworker.Handle(c, j, func(vars string, _ map[string]string) (map[string]any, error) {
				var jv documentRequest
				if err := json.Unmarshal([]byte(vars), &jv); err != nil {
					return nil, err
				}
				var resp documentResponse
				if err := zeebeworker.CallPOST(baseURL, "/documents/generate", jv, &resp); err != nil {
					return nil, err
				}
				return map[string]any{"documentation": resp}, nil
			})
		}).
		Name("pe-documents-worker").
		FetchVariables("documentationResult", "provider").
		Open()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("shutting down")
	worker.Close()
	_ = srv.Shutdown(nil)
	_ = client.Close()
}
