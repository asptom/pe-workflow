package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
	"github.com/pe-workflow/services/internal/zeebeworker"
)

const port = ":8083"
const baseURL = "http://localhost:8083"

type siteVisitRequest struct {
	SiteVisitOutcome string         `json:"siteVisitOutcome"`
	Provider         map[string]any `json:"provider"`
}

type siteVisitResponse struct {
	SiteVerified     bool   `json:"siteVerified"`
	FollowUpDate     string `json:"followUpDate"`
	FollowUpRequired bool   `json:"followUpRequired"`
}

func handleProcessSiteVisit(w http.ResponseWriter, r *http.Request) {
	var req siteVisitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	resp := siteVisitResponse{
		SiteVerified:     req.SiteVisitOutcome == "Passed",
		FollowUpRequired: req.SiteVisitOutcome != "Passed",
	}
	if !resp.SiteVerified {
		resp.FollowUpDate = time.Now().Add(14 * 24 * time.Hour).UTC().Format(time.RFC3339)
	}
	json.NewEncoder(w).Encode(resp)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /site-visit/process", handleProcessSiteVisit)

	srv := &http.Server{Addr: port, Handler: mux}
	go func() {
		log.Printf("scheduling-service listening on %s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	client, err := zeebeworker.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	worker := client.NewJobWorker().
		JobType("process-site-visit").
		Handler(func(c worker.JobClient, j entities.Job) {
			zeebeworker.Handle(c, j, func(vars string, _ map[string]string) (map[string]any, error) {
				var jv struct {
					SiteVisitOutcome string         `json:"siteVisitOutcome"`
					Provider         map[string]any `json:"provider"`
				}
				if err := json.Unmarshal([]byte(vars), &jv); err != nil {
					return nil, err
				}
				var resp siteVisitResponse
				if err := zeebeworker.CallPOST(baseURL, "/site-visit/process", jv, &resp); err != nil {
					return nil, err
				}
				provider := jv.Provider
				if provider == nil {
					provider = map[string]any{}
				}
				provider["siteVerified"] = resp.SiteVerified
				provider["followUpDate"] = resp.FollowUpDate
				provider["followUpRequired"] = resp.FollowUpRequired
				return map[string]any{
					"provider":         provider,
					"followUpDate":     resp.FollowUpDate,
					"followUpRequired": resp.FollowUpRequired,
				}, nil
			})
		}).
		Name("pe-scheduling-worker").
		FetchVariables("provider", "siteVisitOutcome").
		Open()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("shutting down")
	worker.Close()
	_ = srv.Shutdown(nil)
	_ = client.Close()
}
