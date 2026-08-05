// Package zeebeworker provides shared Zeebe client bootstrap and job handling
// helpers used by the pe-workflow microservices.
package zeebeworker

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/entities"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/worker"
	"github.com/camunda-community-hub/zeebe-client-go/v8/pkg/zbc"
)

// NewClient builds a Zeebe client from the standard environment variables.
func NewClient() (zbc.Client, error) {
	creds, err := zbc.NewOAuthCredentialsProvider(&zbc.OAuthProviderConfig{})
	if err != nil {
		return nil, fmt.Errorf("oauth provider: %w", err)
	}
	client, err := zbc.NewClient(&zbc.ClientConfig{
		GatewayAddress:         envOr("ZEEBE_ADDRESS", "camunda-zeebe-gateway:26500"),
		UsePlaintextConnection: true,
		CredentialsProvider:    creds,
	})
	if err != nil {
		return nil, fmt.Errorf("zeebe client: %w", err)
	}
	return client, nil
}

// HandlerFunc adapts an HTTP-calling handler to the client's JobHandler. It
// receives the raw job variables JSON and the custom headers.
type HandlerFunc func(vars string, headers map[string]string) (map[string]any, error)

// Handle runs fn for a job, completing it on success or failing it with
// retries 0 on error.
func Handle(client worker.JobClient, job entities.Job, fn HandlerFunc) {
	fail := func(msg string) {
		fmt.Printf("job %d failed: %s\n", job.Key, msg)
		_, _ = client.NewFailJobCommand().
			JobKey(job.Key).
			Retries(0).
			ErrorMessage(msg).
			Send(context.Background())
	}

	headers, err := job.GetCustomHeadersAsMap()
	if err != nil {
		fail(fmt.Sprintf("read custom headers: %v", err))
		return
	}

	result, err := fn(job.Variables, headers)
	if err != nil {
		fail(err.Error())
		return
	}

	complete, err := client.NewCompleteJobCommand().
		JobKey(job.Key).
		VariablesFromObject(result)
	if err != nil {
		fail(fmt.Sprintf("marshal completion variables: %v", err))
		return
	}
	if _, err := complete.Send(context.Background()); err != nil {
		fmt.Printf("job %d complete failed: %v\n", job.Key, err)
	}
}

// CallPOST posts body to the service's own HTTP API and decodes resp.
func CallPOST(baseURL, path string, body any, out any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+path, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("POST %s returned %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
