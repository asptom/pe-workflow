package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
	"github.com/pe-workflow/services/internal/zeebeworker"
)

const port = ":8081"
const baseURL = "http://localhost:8081"

type screenRequest struct {
	NPI       string `json:"npi"`
	LegalName string `json:"legalName"`
	State     string `json:"state"`
	TIN       string `json:"tin"`
}

type screenResponse struct {
	Cleared    bool   `json:"cleared"`
	RiskScore  int    `json:"riskScore"`
	Source     string `json:"source"`
	ScreenedAt string `json:"screenedAt"`
}

func riskScore(npi, state string) int {
	score := 30
	if npi != "" {
		if last := npi[len(npi)-1]; last >= '0' && last <= '9' && int(last-'0')%2 == 1 {
			score += 25
		}
	}
	if state == "" {
		score += 20
	}
	return score
}

func handleScreenOIG(w http.ResponseWriter, r *http.Request) {
	var req screenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cleared := !strings.Contains(req.LegalName, "EXCLUDED")
	json.NewEncoder(w).Encode(screenResponse{
		Cleared:    cleared,
		RiskScore:  riskScore(req.NPI, req.State),
		Source:     "OIG",
		ScreenedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

func handleScreenSAM(w http.ResponseWriter, r *http.Request) {
	var req screenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	cleared := !strings.Contains(req.LegalName, "DEBARRED")
	json.NewEncoder(w).Encode(screenResponse{
		Cleared:    cleared,
		RiskScore:  riskScore(req.NPI, req.State),
		Source:     "SAM",
		ScreenedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

type provider struct {
	NPI       string `json:"npi"`
	LegalName string `json:"legalName"`
	State     string `json:"state"`
	TIN       string `json:"tin"`
}

type jobVars struct {
	Provider provider `json:"provider"`
}

func screenHandler(path string) zeebeworker.HandlerFunc {
	return func(vars string, _ map[string]string) (map[string]any, error) {
		var jv jobVars
		if err := json.Unmarshal([]byte(vars), &jv); err != nil {
			return nil, err
		}
		var resp screenResponse
		if err := zeebeworker.CallPOST(baseURL, path, jv.Provider, &resp); err != nil {
			return nil, err
		}
		if path == "/screen/oig" {
			return map[string]any{
				"oigCleared":        resp.Cleared,
				"providerRiskScore": resp.RiskScore,
				"oigScreening":      resp,
			}, nil
		}
		return map[string]any{
			"samCleared":   resp.Cleared,
			"samScreening": resp,
		}, nil
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /screen/oig", handleScreenOIG)
	mux.HandleFunc("POST /screen/sam", handleScreenSAM)

	srv := &http.Server{Addr: port, Handler: mux}
	go func() {
		log.Printf("eligibility-service listening on %s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	client, err := zeebeworker.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	handler := func(c worker.JobClient, job entities.Job, path string) {
		zeebeworker.Handle(c, job, screenHandler(path))
	}
	workers := []worker.JobWorker{
		client.NewJobWorker().JobType("screen-oig").Handler(func(c worker.JobClient, j entities.Job) {
			handler(c, j, "/screen/oig")
		}).Name("pe-eligibility-worker").FetchVariables("provider").Open(),
		client.NewJobWorker().JobType("screen-sam").Handler(func(c worker.JobClient, j entities.Job) {
			handler(c, j, "/screen/sam")
		}).Name("pe-eligibility-worker").FetchVariables("provider").Open(),
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("shutting down")
	for _, w := range workers {
		w.Close()
	}
	_ = srv.Shutdown(nil)
	_ = client.Close()
}
