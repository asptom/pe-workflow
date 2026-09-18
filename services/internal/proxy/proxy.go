package proxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/pe-workflow/services/internal/auth"
)

type UpstreamError struct {
	Status  int
	Message string
	Err     error
}

func (e *UpstreamError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	if e.Err != nil {
		return e.Err.Error()
	}
	return fmt.Sprintf("upstream returned %d", e.Status)
}
func (e *UpstreamError) Unwrap() error { return e.Err }

type Client struct {
	base   string
	tokens *auth.TokenManager
	http   *http.Client
	on401  func()
}

func NewClient(base string, tokens *auth.TokenManager, client *http.Client) (*Client, error) {
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	u, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("invalid Zeebe REST address %q", base)
	}
	return &Client{base: strings.TrimRight(base, "/"), tokens: tokens, http: client}, nil
}
func (c *Client) On401(fn func()) { c.on401 = fn }

func (c *Client) Do(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	for attempt := 0; attempt < 2; attempt++ {
		req, err := http.NewRequestWithContext(ctx, method, c.base+"/"+strings.TrimLeft(path, "/"), bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		if len(body) > 0 {
			req.Header.Set("Content-Type", "application/json")
		}
		tok, err := c.tokens.Token(ctx)
		if err != nil {
			return nil, &UpstreamError{Status: 0, Message: "unable to acquire upstream token", Err: err}
		}
		req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
		resp, err := c.http.Do(req)
		if err != nil {
			return nil, &UpstreamError{Status: 0, Err: err}
		}
		if resp.StatusCode != http.StatusUnauthorized || attempt == 1 {
			return resp, nil
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if c.on401 != nil {
			c.on401()
		}
		if err := c.tokens.ForceRefresh(ctx); err != nil {
			return nil, &UpstreamError{Status: 401, Message: "unable to refresh upstream token", Err: err}
		}
	}
	return nil, fmt.Errorf("unreachable")
}

func ReadError(resp *http.Response) string {
	data, _ := io.ReadAll(resp.Body)
	var payload struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(data, &payload) == nil && payload.Message != "" {
		return payload.Message
	}
	return strings.TrimSpace(string(data))
}
