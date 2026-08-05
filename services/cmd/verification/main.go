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

const port = ":8082"
const baseURL = "http://localhost:8082"

type provider struct {
	EntityType              string  `json:"entityType"`
	LicenseNumber           string  `json:"licenseNumber"`
	StateLicenseNumber      string  `json:"stateLicenseNumber"`
	NPI                     string  `json:"npi"`
	TIN                     string  `json:"tin"`
	SuretyBondAmount        float64 `json:"suretyBondAmount"`
	EquipmentLicenseNumber  string  `json:"equipmentLicenseNumber"`
	FireSafetyCertification string  `json:"fireSafetyCertification"`
}

type validResponse struct {
	Valid bool `json:"valid"`
}

func luhnCheckDigit(s string) int {
	sum := 0
	double := true
	for i := len(s) - 1; i >= 0; i-- {
		d := int(s[i] - '0')
		if double {
			d *= 2
			if d > 9 {
				d -= 9
			}
		}
		sum += d
		double = !double
	}
	return (10 - (sum % 10)) % 10
}

func isDigits(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func handleVerifyNPI(w http.ResponseWriter, r *http.Request) {
	var req struct {
		NPI string `json:"npi"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	valid := false
	if len(req.NPI) == 10 && isDigits(req.NPI) {
		check := luhnCheckDigit("80840" + req.NPI[0:9])
		valid = check == int(req.NPI[9]-'0')
	}
	json.NewEncoder(w).Encode(map[string]any{"valid": valid, "active": valid})
}

func handleVerifyTIN(w http.ResponseWriter, r *http.Request) {
	var req struct {
		TIN string `json:"tin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	valid := len(req.TIN) == 9 && isDigits(req.TIN)
	if valid {
		allZero := true
		for _, c := range req.TIN {
			if c != '0' {
				allZero = false
				break
			}
		}
		valid = !allZero
	}
	json.NewEncoder(w).Encode(map[string]any{
		"valid":     valid,
		"checkedAt": time.Now().UTC().Format(time.RFC3339),
	})
}

func handleVerifyLicense(w http.ResponseWriter, r *http.Request) {
	var req struct {
		EntityType         string `json:"entityType"`
		LicenseNumber      string `json:"licenseNumber"`
		StateLicenseNumber string `json:"stateLicenseNumber"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var valid bool
	switch req.EntityType {
	case "Facility":
		valid = req.LicenseNumber != ""
	case "DME Supplier":
		valid = req.StateLicenseNumber != ""
	case "Physician", "NPP":
		valid = req.LicenseNumber != ""
	}
	json.NewEncoder(w).Encode(validResponse{Valid: valid})
}

func handleVerifyBond(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SuretyBondAmount float64 `json:"suretyBondAmount"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	json.NewEncoder(w).Encode(validResponse{Valid: req.SuretyBondAmount >= 50000})
}

func handleVerifyEquipment(w http.ResponseWriter, r *http.Request) {
	var req struct {
		EquipmentLicenseNumber string `json:"equipmentLicenseNumber"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	json.NewEncoder(w).Encode(validResponse{Valid: req.EquipmentLicenseNumber != ""})
}

func handleVerifyFireSafety(w http.ResponseWriter, r *http.Request) {
	var req struct {
		FireSafetyCertification string `json:"fireSafetyCertification"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	json.NewEncoder(w).Encode(validResponse{Valid: req.FireSafetyCertification != ""})
}

func handleVerifyBoardCert(w http.ResponseWriter, r *http.Request) {
	var req struct {
		EntityType   string `json:"entityType"`
		LicenseValid bool   `json:"licenseValid"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	json.NewEncoder(w).Encode(map[string]any{"certified": req.EntityType == "Physician" && req.LicenseValid})
}

type jobVars struct {
	Provider     provider `json:"provider"`
	LicenseValid bool     `json:"licenseValid"`
}

type handlerSpec struct {
	jobType  string
	path     string
	fetch    []string
	body     func(jobVars) any
	complete func(valid bool, j jobVars) map[string]any
}

func validHandler(s handlerSpec) zeebeworker.HandlerFunc {
	return func(vars string, _ map[string]string) (map[string]any, error) {
		var jv jobVars
		if err := json.Unmarshal([]byte(vars), &jv); err != nil {
			return nil, err
		}
		var resp validResponse
		if err := zeebeworker.CallPOST(baseURL, s.path, s.body(jv), &resp); err != nil {
			return nil, err
		}
		return s.complete(resp.Valid, jv), nil
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("POST /verify/npi", handleVerifyNPI)
	mux.HandleFunc("POST /verify/tin", handleVerifyTIN)
	mux.HandleFunc("POST /verify/license", handleVerifyLicense)
	mux.HandleFunc("POST /verify/bond", handleVerifyBond)
	mux.HandleFunc("POST /verify/equipment", handleVerifyEquipment)
	mux.HandleFunc("POST /verify/fire-safety", handleVerifyFireSafety)
	mux.HandleFunc("POST /verify/board-cert", handleVerifyBoardCert)

	srv := &http.Server{Addr: port, Handler: mux}
	go func() {
		log.Printf("verification-service listening on %s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	client, err := zeebeworker.NewClient()
	if err != nil {
		log.Fatal(err)
	}

	specs := []handlerSpec{
		{
			jobType: "verify-npi",
			path:    "/verify/npi",
			fetch:   []string{"provider"},
			body:    func(j jobVars) any { return map[string]any{"npi": j.Provider.NPI} },
			complete: func(valid bool, _ jobVars) map[string]any {
				return map[string]any{
					"npiIsActive": valid,
					"npiValidation": map[string]any{
						"valid":     valid,
						"active":    valid,
						"algorithm": "luhn",
					},
				}
			},
		},
		{
			jobType: "verify-tin",
			path:    "/verify/tin",
			fetch:   []string{"provider"},
			body:    func(j jobVars) any { return map[string]any{"tin": j.Provider.TIN} },
			complete: func(valid bool, _ jobVars) map[string]any {
				return map[string]any{
					"tinValid": valid,
					"tinValidation": map[string]any{
						"valid":     valid,
						"checkedAt": time.Now().UTC().Format(time.RFC3339),
					},
				}
			},
		},
		{
			jobType: "verify-license",
			path:    "/verify/license",
			fetch:   []string{"provider"},
			body: func(j jobVars) any {
				return map[string]any{
					"entityType":         j.Provider.EntityType,
					"licenseNumber":      j.Provider.LicenseNumber,
					"stateLicenseNumber": j.Provider.StateLicenseNumber,
				}
			},
			complete: func(valid bool, j jobVars) map[string]any {
				return map[string]any{
					"licenseValid": valid,
					"licenseValidation": map[string]any{
						"valid":      valid,
						"entityType": j.Provider.EntityType,
					},
				}
			},
		},
		{
			jobType: "verify-bond",
			path:    "/verify/bond",
			fetch:   []string{"provider"},
			body:    func(j jobVars) any { return map[string]any{"suretyBondAmount": j.Provider.SuretyBondAmount} },
			complete: func(valid bool, j jobVars) map[string]any {
				return map[string]any{
					"bondValid": valid,
					"bondValidation": map[string]any{
						"valid":            valid,
						"suretyBondAmount": j.Provider.SuretyBondAmount,
					},
				}
			},
		},
		{
			jobType: "verify-equipment",
			path:    "/verify/equipment",
			fetch:   []string{"provider"},
			body: func(j jobVars) any {
				return map[string]any{"equipmentLicenseNumber": j.Provider.EquipmentLicenseNumber}
			},
			complete: func(valid bool, _ jobVars) map[string]any {
				return map[string]any{
					"equipmentLicensureValid": valid,
					"equipmentValidation":     map[string]any{"valid": valid},
				}
			},
		},
		{
			jobType: "verify-fire-safety",
			path:    "/verify/fire-safety",
			fetch:   []string{"provider"},
			body: func(j jobVars) any {
				return map[string]any{"fireSafetyCertification": j.Provider.FireSafetyCertification}
			},
			complete: func(valid bool, _ jobVars) map[string]any {
				return map[string]any{
					"fireSafetyCompliant": valid,
					"fireSafetyValidation": map[string]any{
						"valid": valid,
					},
				}
			},
		},
		{
			jobType: "verify-board-cert",
			path:    "/verify/board-cert",
			fetch:   []string{"provider", "licenseValid"},
			body: func(j jobVars) any {
				return map[string]any{"entityType": j.Provider.EntityType, "licenseValid": j.LicenseValid}
			},
			complete: func(valid bool, j jobVars) map[string]any {
				return map[string]any{
					"boardCertified": valid,
					"boardCertification": map[string]any{
						"certified":  valid,
						"entityType": j.Provider.EntityType,
					},
				}
			},
		},
	}

	workers := make([]worker.JobWorker, 0, len(specs))
	for _, s := range specs {
		workers = append(workers, client.NewJobWorker().
			JobType(s.jobType).
			Handler(func(c worker.JobClient, j entities.Job) {
				zeebeworker.Handle(c, j, validHandler(s))
			}).
			Name("pe-verification-worker").
			FetchVariables(s.fetch...).
			Open())
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
