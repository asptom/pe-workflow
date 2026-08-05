package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
	"github.com/pe-workflow/services/internal/zeebeworker"
)

const port = ":8085"
const baseURL = "http://localhost:8085"

type notificationRequest struct {
	Kind    string `json:"kind"`
	To      string `json:"to"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
}

type notificationResponse struct {
	MessageID string `json:"messageId"`
	Status    string `json:"status"`
}

func handleSend(w http.ResponseWriter, r *http.Request) {
	var req notificationRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	json.NewEncoder(w).Encode(notificationResponse{
		MessageID: "MSG-" + strconv.FormatInt(time.Now().Unix(), 10),
		Status:    "SENT",
	})
}

func mapStr(m map[string]any, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /notifications/send", handleSend)

	srv := &http.Server{Addr: port, Handler: mux}
	go func() {
		log.Printf("notifications-service listening on %s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	client, err := zeebeworker.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	worker := client.NewJobWorker().
		JobType("send-notification").
		Handler(func(c worker.JobClient, j entities.Job) {
			zeebeworker.Handle(c, j, func(vars string, headers map[string]string) (map[string]any, error) {
				var jv struct {
					Provider               map[string]any `json:"provider"`
					EligibilityResult      map[string]any `json:"eligibilityResult"`
					TimelineResult         map[string]any `json:"timelineResult"`
					CMSCertificationNumber string         `json:"cmsCertificationNumber"`
					PTANNumber             string         `json:"ptanNumber"`
					EffectiveDate          string         `json:"effectiveDate"`
					DenialReason           string         `json:"denialReason"`
					Kind                   string         `json:"kind"`
				}
				if err := json.Unmarshal([]byte(vars), &jv); err != nil {
					return nil, err
				}
				if jv.Provider == nil {
					jv.Provider = map[string]any{}
				}
				if jv.EligibilityResult == nil {
					jv.EligibilityResult = map[string]any{}
				}
				if jv.TimelineResult == nil {
					jv.TimelineResult = map[string]any{}
				}

				kind := jv.Kind
				if kind == "" {
					kind = headers["kind"]
				}
				to := mapStr(jv.Provider, "legalName")
				req := notificationRequest{Kind: kind, To: to}
				switch kind {
				case "ineligibility":
					req.Subject = "Enrollment ineligible"
					req.Body = "Your enrollment is ineligible: " + mapStr(jv.EligibilityResult, "eligibilityStatus") + ". Provider: " + to
				case "additional-info":
					req.Subject = "Additional information required"
					req.Body = "Additional information requested. Status: " + mapStr(jv.EligibilityResult, "eligibilityStatus") + ". Response deadline: 30 days."
				case "cms-forward":
					req.To = "CMS Provider Enrollment"
					req.Subject = "Enrollment application forwarded"
					req.Body = "Complete application forwarded to CMS. Timeline: " + mapStr(jv.TimelineResult, "totalEstimateDays") + " days. Provider: " + to
				case "approval":
					req.Subject = "Enrollment approved"
					req.Body = "Approval letter sent. CCN: " + jv.CMSCertificationNumber + ". PTAN: " + jv.PTANNumber + ". Effective: " + jv.EffectiveDate
				case "denial":
					req.Subject = "Enrollment denied"
					req.Body = "Denial letter sent. Reason: " + jv.DenialReason + ". Provider may appeal or resubmit."
				default:
					return nil, fmt.Errorf("unknown notification kind %q", kind)
				}

				var resp notificationResponse
				if err := zeebeworker.CallPOST(baseURL, "/notifications/send", req, &resp); err != nil {
					return nil, err
				}
				return map[string]any{"notificationStatus": "Sent: " + kind + " to " + req.To}, nil
			})
		}).
		Name("pe-notifications-worker").
		FetchVariables("provider", "eligibilityResult", "timelineResult", "cmsCertificationNumber", "ptanNumber", "effectiveDate", "denialReason", "kind").
		Open()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("shutting down")
	worker.Close()
	_ = srv.Shutdown(nil)
	_ = client.Close()
}
