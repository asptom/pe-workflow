package auth

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/clientcredentials"
)

type TokenManager struct {
	mu  sync.Mutex
	cfg clientcredentials.Config
	src oauth2.TokenSource
}

func NewTokenManager(cfg clientcredentials.Config) *TokenManager {
	return &TokenManager{cfg: cfg, src: cfg.TokenSource(context.Background())}
}

func NewTokenManagerFromEnv() (*TokenManager, error) {
	if err := ValidateEnv(); err != nil {
		return nil, err
	}
	audience := os.Getenv("ZEEBE_TOKEN_AUDIENCE")
	if audience == "" {
		audience = "orchestration"
	}
	return NewTokenManager(clientcredentials.Config{
		TokenURL:     os.Getenv("ZEEBE_AUTHORIZATION_SERVER_URL"),
		ClientID:     os.Getenv("ZEEBE_CLIENT_ID"),
		ClientSecret: os.Getenv("ZEEBE_CLIENT_SECRET"),
		EndpointParams: url.Values{
			"audience": {audience},
		},
	}), nil
}

func ValidateEnv() error {
	for _, name := range []string{"ZEEBE_AUTHORIZATION_SERVER_URL", "ZEEBE_CLIENT_ID", "ZEEBE_CLIENT_SECRET", "ZEEBE_REST_ADDRESS"} {
		if strings.TrimSpace(os.Getenv(name)) == "" {
			return fmt.Errorf("required environment variable %s is missing", name)
		}
	}
	return nil
}

func (m *TokenManager) Token(ctx context.Context) (*oauth2.Token, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.src.Token()
}

func (m *TokenManager) ForceRefresh(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	fresh := m.cfg.TokenSource(ctx)
	if _, err := fresh.Token(); err != nil {
		return err
	}
	m.src = fresh
	return nil
}
