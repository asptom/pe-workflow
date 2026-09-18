package auth

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"golang.org/x/oauth2/clientcredentials"
)

func TestForceRefreshReplacesTokenSource(t *testing.T) {
	calls := 0
	tokens := []string{"first", "second"}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"` + tokens[calls-1] + `","token_type":"Bearer","expires_in":3600}`))
	}))
	defer ts.Close()
	m := NewTokenManager(clientcredentials.Config{TokenURL: ts.URL, ClientID: "id", ClientSecret: "secret", EndpointParams: url.Values{"audience": {"orchestration"}}})
	first, err := m.Token(context.Background())
	if err != nil || first.AccessToken != "first" {
		t.Fatalf("first token: %#v %v", first, err)
	}
	if err := m.ForceRefresh(context.Background()); err != nil {
		t.Fatal(err)
	}
	second, err := m.Token(context.Background())
	if err != nil || second.AccessToken != "second" {
		t.Fatalf("second token: %#v %v", second, err)
	}
	if calls != 2 {
		t.Fatalf("token endpoint calls = %d", calls)
	}
}
