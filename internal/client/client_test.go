package client

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

// fastConfig returns a Config with no real sleeping and deterministic jitter.
func fastConfig(url string) (Config, *[]time.Duration) {
	var slept []time.Duration
	cfg := Config{
		BaseURL:     url,
		Token:       "test-token",
		BaseBackoff: 100 * time.Millisecond,
		MaxBackoff:  time.Second,
		Sleep:       func(d time.Duration) { slept = append(slept, d) },
		Jitter:      func() float64 { return 0.5 },
	}
	return cfg, &slept
}

func gqlOK(t *testing.T, w http.ResponseWriter, data string) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	if _, err := w.Write([]byte(`{"data":` + data + `}`)); err != nil {
		t.Fatalf("write response: %v", err)
	}
}

func decodeRequest(t *testing.T, r *http.Request) (query string, variables map[string]any) {
	t.Helper()
	var body struct {
		Query     string         `json:"query"`
		Variables map[string]any `json:"variables"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		t.Fatalf("decode request: %v", err)
	}
	return body.Query, body.Variables
}

func TestExecuteHappyPathSendsHeadersAndDecodes(t *testing.T) {
	var gotPath, gotAuth, gotCorr, gotContentType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotCorr = r.Header.Get("X-Correlation-Id")
		gotContentType = r.Header.Get("Content-Type")
		gqlOK(t, w, `{"apiVersion":"2026-08-01"}`)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	c := New(cfg)
	version, err := c.APIVersion(context.Background(), "corr-123")
	if err != nil {
		t.Fatalf("APIVersion: %v", err)
	}
	if version != "2026-08-01" {
		t.Errorf("apiVersion = %q, want 2026-08-01", version)
	}
	if gotPath != "/graphql" {
		t.Errorf("path = %q, want /graphql", gotPath)
	}
	if gotAuth != "Bearer test-token" {
		t.Errorf("Authorization = %q", gotAuth)
	}
	if gotCorr != "corr-123" {
		t.Errorf("X-Correlation-Id = %q, want corr-123", gotCorr)
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q", gotContentType)
	}
}

func TestEndpointNormalization(t *testing.T) {
	for base, want := range map[string]string{
		"http://x:4000":          "http://x:4000/graphql",
		"http://x:4000/":         "http://x:4000/graphql",
		"http://x:4000/graphql":  "http://x:4000/graphql",
		"http://x:4000/graphql/": "http://x:4000/graphql",
	} {
		if got := New(Config{BaseURL: base}).Endpoint(); got != want {
			t.Errorf("Endpoint(%q) = %q, want %q", base, got, want)
		}
	}
}

func TestRetryOn503ThenSuccessWithBackoff(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) <= 2 {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		gqlOK(t, w, `{"apiVersion":"v1"}`)
	}))
	defer srv.Close()

	cfg, slept := fastConfig(srv.URL)
	c := New(cfg)
	version, err := c.APIVersion(context.Background(), "corr-retry")
	if err != nil {
		t.Fatalf("APIVersion after retries: %v", err)
	}
	if version != "v1" {
		t.Errorf("apiVersion = %q", version)
	}
	if calls.Load() != 3 {
		t.Errorf("server calls = %d, want 3", calls.Load())
	}
	// Equal jitter with jitter=0.5: 100ms -> 75ms, 200ms -> 150ms.
	want := []time.Duration{75 * time.Millisecond, 150 * time.Millisecond}
	if len(*slept) != len(want) {
		t.Fatalf("sleeps = %v, want %v", *slept, want)
	}
	for i := range want {
		if (*slept)[i] != want[i] {
			t.Errorf("sleep[%d] = %v, want %v", i, (*slept)[i], want[i])
		}
	}
}

func TestRetryExhaustedMapsToTransportError(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	cfg.MaxAttempts = 3
	c := New(cfg)
	_, err := c.APIVersion(context.Background(), "corr-exhaust")
	var transport *TransportError
	if !errors.As(err, &transport) {
		t.Fatalf("error = %v (%T), want *TransportError", err, err)
	}
	if transport.Attempts != 3 || calls.Load() != 3 {
		t.Errorf("attempts = %d, calls = %d, want 3/3", transport.Attempts, calls.Load())
	}
	var httpErr *HTTPError
	if !errors.As(transport.Err, &httpErr) || httpErr.StatusCode != 500 {
		t.Errorf("underlying = %v, want HTTP 500", transport.Err)
	}
}

func TestNetworkErrorRetriesThenTransportError(t *testing.T) {
	// Reserve a port and close it so every dial fails fast.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()

	cfg, slept := fastConfig("http://" + addr)
	cfg.MaxAttempts = 2
	c := New(cfg)
	_, err = c.APIVersion(context.Background(), "corr-net")
	var transport *TransportError
	if !errors.As(err, &transport) {
		t.Fatalf("error = %v (%T), want *TransportError", err, err)
	}
	if len(*slept) != 1 {
		t.Errorf("retries = %d, want 1", len(*slept))
	}
}

func TestHTTP401MapsToAuthError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusUnauthorized)
	}))
	defer srv.Close()

	cfg, slept := fastConfig(srv.URL)
	c := New(cfg)
	_, err := c.APIVersion(context.Background(), "corr-auth")
	var auth *AuthError
	if !errors.As(err, &auth) {
		t.Fatalf("error = %v (%T), want *AuthError", err, err)
	}
	if len(*slept) != 0 {
		t.Errorf("auth failures must not be retried; slept %v", *slept)
	}
}

func TestTopLevelGraphQLErrors(t *testing.T) {
	t.Run("unauthenticated maps to AuthError", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(`{"data":null,"errors":[{"message":"unauthenticated"}]}`))
		}))
		defer srv.Close()
		cfg, _ := fastConfig(srv.URL)
		_, err := New(cfg).APIVersion(context.Background(), "corr")
		var auth *AuthError
		if !errors.As(err, &auth) {
			t.Fatalf("error = %v (%T), want *AuthError", err, err)
		}
	})
	t.Run("live-server UNAUTHENTICATED code maps to AuthError", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Exact shape observed from the Billing Core server.
			w.Write([]byte(`{"data":{"viewer":null},"errors":[{"code":"UNAUTHENTICATED","message":"authentication required","path":["viewer"]}]}`))
		}))
		defer srv.Close()
		cfg, _ := fastConfig(srv.URL)
		_, err := New(cfg).Status(context.Background(), "corr")
		var auth *AuthError
		if !errors.As(err, &auth) {
			t.Fatalf("error = %v (%T), want *AuthError", err, err)
		}
	})
	t.Run("other errors map to GraphQLError", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Write([]byte(`{"data":null,"errors":[{"message":"Argument \"asOf\" has invalid value"}]}`))
		}))
		defer srv.Close()
		cfg, _ := fastConfig(srv.URL)
		_, err := New(cfg).APIVersion(context.Background(), "corr")
		var gql *GraphQLError
		if !errors.As(err, &gql) {
			t.Fatalf("error = %v (%T), want *GraphQLError", err, err)
		}
	})
}

func TestCreateSubscriptionValidationProblem(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gqlOK(t, w, `{"createSubscription":{
			"__typename":"ValidationProblem",
			"code":"invalid_input",
			"message":"quantity must be positive",
			"fields":[{"path":["input","quantity"],"code":"must_be_positive","message":"must be positive"}]
		}}`)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	c := New(cfg)
	_, err := c.CreateSubscription(context.Background(), "corr-vp", CreateSubscriptionInput{
		TeamID: "team-1", ContractID: "c-1", ExternalID: "x", PlanVersionID: "pv-1", StartsOn: "2026-09-01", Quantity: "-1",
	})
	var problem *ProblemError
	if !errors.As(err, &problem) {
		t.Fatalf("error = %v (%T), want *ProblemError", err, err)
	}
	if problem.Kind != ProblemValidation {
		t.Errorf("kind = %q, want validation", problem.Kind)
	}
	if problem.Code != "invalid_input" || len(problem.Fields) != 1 || problem.Fields[0].Code != "must_be_positive" {
		t.Errorf("unexpected problem payload: %+v", problem)
	}
}

func TestIdempotencyConflictMapping(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gqlOK(t, w, `{"bookInvoice":{"__typename":"IdempotencyConflict","code":"idempotency_conflict","message":"key reused with different input"}}`)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	_, err := New(cfg).BookInvoice(context.Background(), "corr-ic", BookInvoiceInput{TeamID: "t", InvoiceIntentID: "i"})
	var problem *ProblemError
	if !errors.As(err, &problem) || problem.Kind != ProblemIdempotencyConflict {
		t.Fatalf("error = %v, want idempotency conflict problem", err)
	}
}

func TestCreateSubscriptionAutoIdempotencyKeyAndClientMutationID(t *testing.T) {
	var captured map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, vars := decodeRequest(t, r)
		captured = vars["input"].(map[string]any)
		gqlOK(t, w, `{"createSubscription":{"__typename":"CreateSubscriptionSuccess","subscription":{
			"id":"s-1","externalId":"x","contractId":"c-1","state":"active","startsOn":"2026-09-01",
			"timeZone":"Europe/Copenhagen","version":1,"currentVersion":1}}}`)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	sub, err := New(cfg).CreateSubscription(context.Background(), "corr-idem", CreateSubscriptionInput{
		TeamID: "team-1", ContractID: "c-1", ExternalID: "x", PlanVersionID: "pv-1", StartsOn: "2026-09-01", Quantity: "3",
	})
	if err != nil {
		t.Fatalf("CreateSubscription: %v", err)
	}
	if sub.ID != "s-1" {
		t.Errorf("subscription id = %q", sub.ID)
	}
	key, _ := captured["idempotencyKey"].(string)
	if _, err := uuid.Parse(key); err != nil {
		t.Errorf("idempotencyKey = %q, want generated UUID", key)
	}
	if cmid, _ := captured["clientMutationId"].(string); cmid != "corr-idem" {
		t.Errorf("clientMutationId = %q, want correlation ID", cmid)
	}
	if q, _ := captured["quantity"].(string); q != "3" {
		t.Errorf("quantity sent as %T %v, want string \"3\" (Decimal scalar rejects floats)", captured["quantity"], captured["quantity"])
	}
}

func TestExplicitIdempotencyKeyIsForwarded(t *testing.T) {
	var captured map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, vars := decodeRequest(t, r)
		captured = vars["input"].(map[string]any)
		gqlOK(t, w, `{"freezeInvoiceIntent":{"__typename":"FreezeInvoiceIntentSuccess","invoiceIntent":{
			"id":"ii-1","state":"frozen","customerId":"cu-1","customerVersion":1,"currency":"DKK",
			"invoiceDate":"2026-09-01","intentVersion":1,"documentKind":"invoice","contentHash":"h","netAmountMinor":1000,"lines":[]}}}`)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	_, err := New(cfg).FreezeInvoiceIntent(context.Background(), "corr", FreezeInvoiceIntentInput{
		TeamID: "t", SubscriptionID: "s", AsOf: "2026-09-01", IdempotencyKey: "explicit-key",
	})
	if err != nil {
		t.Fatalf("FreezeInvoiceIntent: %v", err)
	}
	if key, _ := captured["idempotencyKey"].(string); key != "explicit-key" {
		t.Errorf("idempotencyKey = %q, want explicit-key", key)
	}
}

func TestCustomerNotFound(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gqlOK(t, w, `{"customer":null}`)
	}))
	defer srv.Close()

	cfg, _ := fastConfig(srv.URL)
	_, err := New(cfg).Customer(context.Background(), "corr", "team-1", "missing-id")
	var notFound *NotFoundError
	if !errors.As(err, &notFound) {
		t.Fatalf("error = %v (%T), want *NotFoundError", err, err)
	}
}

// TestLiveSmoke exercises the real server when BILLING_URL is set; it is
// skipped in CI by default.
func TestLiveSmoke(t *testing.T) {
	url := os.Getenv("BILLING_URL")
	if url == "" {
		t.Skip("BILLING_URL not set; skipping live smoke test")
	}
	c := New(Config{BaseURL: url, Token: os.Getenv("BILLING_TOKEN")})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	version, err := c.APIVersion(ctx, NewCorrelationID())
	if err != nil {
		t.Fatalf("live apiVersion: %v", err)
	}
	if version == "" {
		t.Error("live apiVersion is empty")
	}
	t.Logf("live apiVersion: %s", version)
}
