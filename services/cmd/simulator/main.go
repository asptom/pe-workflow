package main

import (
	"encoding/json"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
	"github.com/pe-workflow/services/internal/zeebeworker"
)

const port = ":8086"

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	srv := &http.Server{Addr: port, Handler: mux}
	go func() {
		log.Printf("simulator-service listening on %s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	client, err := zeebeworker.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	simulateSA := client.NewJobWorker().
		JobType("simulate-sa-review").
		Handler(func(c worker.JobClient, j entities.Job) {
			zeebeworker.Handle(c, j, func(vars string, headers map[string]string) (map[string]any, error) {
				var jv struct {
					Force string `json:"force"`
					Phase string `json:"phase"`
				}
				_ = json.Unmarshal([]byte(vars), &jv)
				force := jv.Force
				if force == "" {
					force = headers["force"]
				}
				phase := jv.Phase
				if phase == "" {
					phase = headers["phase"]
				}
				time.Sleep(time.Duration(2+rand.IntN(3)) * time.Second)
				responded := rand.IntN(2) == 1
				switch force {
				case "responded":
					responded = true
				case "timeout":
					responded = false
				}
				outcome := "No response"
				if responded {
					outcome = "Responded"
				}
				log.Printf("job %d: simulate-sa-review phase=%s responded=%t", j.Key, phase, responded)
				return map[string]any{
					"saAoResponseReceived": responded,
					"saAoOutcome":          outcome,
				}, nil
			})
		}).
		Name("pe-simulator-sa-review-worker").
		Open()

	simulateCMS := client.NewJobWorker().
		JobType("simulate-cms-decision").
		Handler(func(c worker.JobClient, j entities.Job) {
			zeebeworker.Handle(c, j, func(vars string, headers map[string]string) (map[string]any, error) {
				var jv struct {
					Force string `json:"force"`
				}
				_ = json.Unmarshal([]byte(vars), &jv)
				force := jv.Force
				if force == "" {
					force = headers["force"]
				}
				time.Sleep(time.Duration(2+rand.IntN(3)) * time.Second)
				decision := "Denied"
				switch force {
				case "Approved":
					decision = "Approved"
				case "Denied":
					decision = "Denied"
				default:
					if rand.IntN(2) == 1 {
						decision = "Approved"
					}
				}
				log.Printf("job %d: simulate-cms-decision decision=%s", j.Key, decision)
				return map[string]any{"cmsDecision": decision}, nil
			})
		}).
		Name("pe-simulator-cms-decision-worker").
		Open()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("shutting down")
	simulateSA.Close()
	simulateCMS.Close()
	_ = srv.Shutdown(nil)
	_ = client.Close()
}
