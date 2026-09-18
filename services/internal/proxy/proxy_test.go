package proxy

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/pe-workflow/services/internal/auth"
	"golang.org/x/oauth2/clientcredentials"
)

func TestClientRetriesUnauthorizedOnce(t *testing.T) {
	calls := 0
	tokens := []string{"stale", "fresh"}
	tokenServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"` + tokens[0] + `","token_type":"Bearer","expires_in":3600}`))
	}))
	defer tokenServer.Close()
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer upstream.Close()
	manager := auth.NewTokenManager(clientcredentials.Config{TokenURL: tokenServer.URL, ClientID: "id", ClientSecret: "secret", EndpointParams: url.Values{"audience": {"orchestration"}}})
	client, err := NewClient(upstream.URL, manager, upstream.Client())
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(context.Background(), http.MethodGet, "/resource", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK || calls != 2 {
		t.Fatalf("status=%d calls=%d", resp.StatusCode, calls)
	}
}
