// Package client implements the authenticated Billing Core GraphQL client
// shared by revryn commands and the MCP server (SPEC §12.2.3, INV-045).
//
// The client is a *client* of the public GraphQL contract: it never talks to
// PostgreSQL or internal contexts, and generated GraphQL documents are an
// implementation detail (SPEC §14.14).
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
)

// DefaultBaseURL is used when no --url flag or BILLING_URL env is provided.
const DefaultBaseURL = "http://localhost:4000"

// graphqlPath is the public GraphQL endpoint of Billing Core.
const graphqlPath = "/graphql"

// maxResponseBytes bounds how much of a response body is read (defensive).
const maxResponseBytes = 8 << 20 // 8 MiB

// Config configures a Client. The zero value of optional fields is replaced
// with sensible defaults by New.
type Config struct {
	// BaseURL is the server base URL, e.g. "http://localhost:4000".
	// A trailing "/graphql" is accepted and not duplicated.
	BaseURL string
	// Token is the bearer session token; empty means unauthenticated.
	Token string
	// HTTPClient overrides the underlying *http.Client (default: 30s timeout).
	HTTPClient *http.Client
	// MaxAttempts is the total number of attempts including the first
	// (default 4: one call plus three retries).
	MaxAttempts int
	// BaseBackoff is the backoff before the first retry (default 250ms).
	BaseBackoff time.Duration
	// MaxBackoff caps the exponential backoff (default 5s).
	MaxBackoff time.Duration
	// Sleep is called between retries; injectable for tests (default time.Sleep).
	Sleep func(time.Duration)
	// Jitter returns a value in [0,1); injectable for tests (default math/rand).
	Jitter func() float64
	// UserAgent overrides the User-Agent header.
	UserAgent string
}

// Client is a Billing Core GraphQL client with retry, correlation and
// idempotency support. It is safe for concurrent use.
type Client struct {
	endpoint    string
	token       string
	http        *http.Client
	maxAttempts int
	baseBackoff time.Duration
	maxBackoff  time.Duration
	sleep       func(time.Duration)
	jitter      func() float64
	userAgent   string
}

// New builds a Client from cfg, applying defaults for unset fields.
func New(cfg Config) *Client {
	base := cfg.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	base = strings.TrimRight(base, "/")
	if !strings.HasSuffix(base, graphqlPath) {
		base += graphqlPath
	}
	c := &Client{
		endpoint:    base,
		token:       cfg.Token,
		http:        cfg.HTTPClient,
		maxAttempts: cfg.MaxAttempts,
		baseBackoff: cfg.BaseBackoff,
		maxBackoff:  cfg.MaxBackoff,
		sleep:       cfg.Sleep,
		jitter:      cfg.Jitter,
		userAgent:   cfg.UserAgent,
	}
	if c.http == nil {
		c.http = &http.Client{Timeout: 30 * time.Second}
	}
	if c.maxAttempts <= 0 {
		c.maxAttempts = 4
	}
	if c.baseBackoff <= 0 {
		c.baseBackoff = 250 * time.Millisecond
	}
	if c.maxBackoff <= 0 {
		c.maxBackoff = 5 * time.Second
	}
	if c.sleep == nil {
		c.sleep = time.Sleep
	}
	if c.jitter == nil {
		c.jitter = rand.Float64
	}
	if c.userAgent == "" {
		c.userAgent = "revryn"
	}
	return c
}

// Endpoint returns the resolved GraphQL endpoint URL.
func (c *Client) Endpoint() string { return c.endpoint }

// NewCorrelationID generates a fresh correlation UUID (SPEC §22.10).
func NewCorrelationID() string { return uuid.NewString() }

// NewIdempotencyKey generates a fresh idempotency key UUID (SPEC §14.14).
func NewIdempotencyKey() string { return uuid.NewString() }

type gqlRequest struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables,omitempty"`
}

// GQLErrorItem is a single top-level GraphQL error. Billing Core adds a
// stable machine-readable code (e.g. "UNAUTHENTICATED") at the top level.
type GQLErrorItem struct {
	Message    string         `json:"message"`
	Code       string         `json:"code,omitempty"`
	Path       []any          `json:"path,omitempty"`
	Extensions map[string]any `json:"extensions,omitempty"`
}

type gqlResponse struct {
	Data   json.RawMessage `json:"data"`
	Errors []GQLErrorItem  `json:"errors"`
}

// Execute posts a GraphQL document and decodes the "data" object into out.
//
// It sets Authorization and X-Correlation-Id headers, retries network errors
// and 5xx responses with exponential backoff plus jitter, and maps
// authentication failures and top-level GraphQL errors to typed errors.
func (c *Client) Execute(ctx context.Context, correlationID, query string, variables map[string]any, out any) error {
	body, err := json.Marshal(gqlRequest{Query: query, Variables: variables})
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}

	var lastErr error
	for attempt := 1; attempt <= c.maxAttempts; attempt++ {
		if attempt > 1 {
			c.sleep(c.backoff(attempt - 1))
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", c.userAgent)
		req.Header.Set("X-Correlation-Id", correlationID)
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}

		resp, err := c.http.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			lastErr = err
			continue
		}
		respBody, readErr := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes))
		resp.Body.Close()
		if readErr != nil {
			lastErr = fmt.Errorf("read response: %w", readErr)
			continue
		}

		switch {
		case resp.StatusCode >= 500:
			lastErr = &HTTPError{StatusCode: resp.StatusCode, Body: truncate(string(respBody), 512), CorrelationID: correlationID}
			continue
		case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
			return &AuthError{StatusCode: resp.StatusCode, Message: "authentication failed (HTTP " + fmt.Sprint(resp.StatusCode) + ")", CorrelationID: correlationID}
		case resp.StatusCode != http.StatusOK:
			return &HTTPError{StatusCode: resp.StatusCode, Body: truncate(string(respBody), 512), CorrelationID: correlationID}
		}

		var gr gqlResponse
		if err := json.Unmarshal(respBody, &gr); err != nil {
			return fmt.Errorf("decode response: %w", err)
		}
		if len(gr.Errors) > 0 {
			if authish(gr.Errors) {
				return &AuthError{StatusCode: resp.StatusCode, Message: gr.Errors[0].Message, CorrelationID: correlationID}
			}
			return &GraphQLError{Errors: gr.Errors, CorrelationID: correlationID}
		}
		if out != nil {
			if err := json.Unmarshal(gr.Data, out); err != nil {
				return fmt.Errorf("decode data: %w", err)
			}
		}
		return nil
	}
	return &TransportError{Err: lastErr, Attempts: c.maxAttempts, CorrelationID: correlationID}
}

// backoff returns the delay before retry number n (n >= 1) using equal
// jitter: half fixed exponential, half random.
func (c *Client) backoff(n int) time.Duration {
	d := c.baseBackoff << (n - 1)
	if d > c.maxBackoff || d <= 0 {
		d = c.maxBackoff
	}
	half := d / 2
	return half + time.Duration(c.jitter()*float64(half))
}

// authish reports whether the top-level GraphQL errors indicate an
// authentication/authorization failure rather than a domain error. Billing
// Core reports code UNAUTHENTICATED with message "authentication required".
func authish(errs []GQLErrorItem) bool {
	for _, e := range errs {
		if isAuthCode(e.Code) {
			return true
		}
		if code, ok := e.Extensions["code"].(string); ok && isAuthCode(code) {
			return true
		}
		msg := strings.ToLower(e.Message)
		if strings.Contains(msg, "unauthenticated") || strings.Contains(msg, "unauthorized") ||
			strings.Contains(msg, "authentication required") {
			return true
		}
	}
	return false
}

func isAuthCode(code string) bool {
	switch strings.ToLower(code) {
	case "unauthenticated", "unauthorized":
		return true
	}
	return false
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
