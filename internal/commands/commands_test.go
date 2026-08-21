package commands

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stubServer answers the GraphQL documents billingctl sends with
// deterministic fixtures, keyed by operation name.
func stubServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		write := func(data string) { w.Write([]byte(`{"data":` + data + `}`)) }
		switch {
		case strings.Contains(body.Query, "BillingctlStatus"):
			write(`{"apiVersion":"2026-08-01","viewer":{
				"id":"7f9d3f9a-0000-0000-0000-000000000001","status":"active","platformAdmin":false,
				"organizationMemberships":[{"organization":{"id":"org-1","name":"Acme","slug":"acme","status":"active"},"roles":["admin"]}],
				"teamMemberships":[{"team":{"id":"team-1","organizationId":"org-1","name":"Acme DK","slug":"acme-dk","legalName":"Acme ApS","baseCurrency":"DKK","timeZone":"Europe/Copenhagen","locale":"da-DK","status":"active"},"roles":["finance"]}]}}`)
		case strings.Contains(body.Query, "BillingctlAPIVersion"):
			write(`{"apiVersion":"2026-08-01"}`)
		case strings.Contains(body.Query, "BillingctlCustomers"):
			write(`{"customers":{"edges":[
				{"cursor":"c1","node":{"id":"cu-1","externalId":"crm-1001","status":"active","currentVersion":2,"legalName":"Nordisk Regnskab ApS"}},
				{"cursor":"c2","node":{"id":"cu-2","externalId":"crm-1002","status":"active","currentVersion":1,"legalName":null}}],
				"pageInfo":{"hasNextPage":true,"endCursor":"c2"}}}`)
		case strings.Contains(body.Query, "BillingctlCustomer("):
			id, _ := body.Variables["id"].(string)
			if id == "missing" {
				write(`{"customer":null}`)
				return
			}
			write(`{"customer":{"id":"cu-1","externalId":"crm-1001","status":"active","currentVersion":2,"legalName":"Nordisk Regnskab ApS"}}`)
		case strings.Contains(body.Query, "BillingctlInvoicePreview"):
			write(`{"invoicePreview":{
				"subscriptionId":"sub-1","customerId":"cu-1","contractId":"con-1","currency":"DKK",
				"invoiceDate":"2026-09-01","periodStart":"2026-09-01","periodEndExclusive":"2026-10-01",
				"netAmountMinor":250000,"fingerprint":"fp-abc","blockers":[],
				"lines":[{"lineKey":"lk-1","description":"Standard plan","quantity":"2","amountMinor":250000,
					"recognitionMode":"over_time","serviceStart":"2026-09-01","serviceEndExclusive":"2026-10-01",
					"ordinal":1,"productId":"prod-1"}]}}`)
		case strings.Contains(body.Query, "BillingctlCreateSubscription"):
			input, _ := body.Variables["input"].(map[string]any)
			if q, _ := input["quantity"].(string); q == "-1" {
				write(`{"createSubscription":{"__typename":"ValidationProblem","code":"invalid_input","message":"quantity must be positive","fields":[{"path":["input","quantity"],"code":"must_be_positive","message":"must be positive"}]}}`)
				return
			}
			write(`{"createSubscription":{"__typename":"CreateSubscriptionSuccess","subscription":{
				"id":"sub-1","externalId":"ext-9","contractId":"con-1","state":"active","startsOn":"2026-09-01",
				"endDateExclusive":null,"billingAnchorDay":null,"timeZone":"Europe/Copenhagen","version":1,"currentVersion":1}}}`)
		case strings.Contains(body.Query, "BillingctlBookInvoice"):
			write(`{"bookInvoice":{"__typename":"IdempotencyConflict","code":"idempotency_conflict","message":"key reused with different input"}}`)
		case strings.Contains(body.Query, "BillingctlCreateBillingRun"):
			input, _ := body.Variables["input"].(map[string]any)
			runKey, _ := input["runKey"].(string)
			cutoff, _ := input["usageCutoff"].(string)
			write(`{"createBillingRun":{"__typename":"CreateBillingRunSuccess","billingRun":{
				"id":"run-uuid-1","runKey":"` + runKey + `","status":"open","invoiceDate":"2026-09-01",
				"usageCutoff":"` + cutoff + `","engineVersion":"1.0.0","startedAt":null,"closedAt":null}}}`)
		default:
			t.Errorf("stub received unexpected query: %s", body.Query)
			write(`null`)
		}
	}))
}

// run executes billingctl with deterministic global flags against url.
func run(t *testing.T, url string, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	var out, errOut bytes.Buffer
	full := append([]string{"--url", url, "--token", "tok", "--team", "team-1", "--correlation-id", "corr-fixed"}, args...)
	code = Execute(full, &out, &errOut, func(string) string { return "" })
	return out.String(), errOut.String(), code
}

// golden compares got with the named file under contracts/cli/golden;
// UPDATE_GOLDEN=1 rewrites the fixtures.
func golden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("..", "..", "contracts", "cli", "golden", name)
	if os.Getenv("UPDATE_GOLDEN") != "" {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s (run with UPDATE_GOLDEN=1 to create): %v", name, err)
	}
	if got != string(want) {
		t.Errorf("output does not match golden %s\n--- got ---\n%s\n--- want ---\n%s", name, got, want)
	}
}

func TestStatusJSONGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, stderr, code := run(t, srv.URL, "status", "--json")
	if code != ExitOK || stderr != "" {
		t.Fatalf("code = %d, stderr = %q", code, stderr)
	}
	golden(t, "status.json", stdout)
}

func TestStatusHuman(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "status")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	for _, want := range []string{"2026-08-01", "team memberships:", "Acme DK", "finance"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("human output missing %q:\n%s", want, stdout)
		}
	}
}

func TestCustomersListJSONGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "customers", "list", "--json")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	golden(t, "customers-list.json", stdout)
}

func TestCustomersListHumanGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "customers", "list")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	golden(t, "customers-list.txt", stdout)
}

func TestInvoicesPreviewJSONGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "invoices", "preview", "--subscription", "sub-1", "--as-of", "2026-09-15", "--json")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	golden(t, "invoices-preview.json", stdout)
}

func TestInvoicesPreviewHumanGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "invoices", "preview", "--subscription", "sub-1", "--as-of", "2026-09-15")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	golden(t, "invoices-preview.txt", stdout)
}

func TestSubscriptionsCreateJSONGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL,
		"subscriptions", "create",
		"--contract", "con-1", "--plan-version", "pv-1", "--external-id", "ext-9",
		"--start", "2026-09-01", "--quantity", "2", "--idempotency-key", "fixed-key", "--json")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	golden(t, "subscriptions-create.json", stdout)
}

func TestValidationErrorJSONGolden(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, stderr, code := run(t, srv.URL,
		"subscriptions", "create",
		"--contract", "con-1", "--plan-version", "pv-1", "--external-id", "ext-9",
		"--start", "2026-09-01", "--quantity", "-1", "--json")
	if code != ExitValidation {
		t.Fatalf("code = %d, want %d", code, ExitValidation)
	}
	if stdout != "" {
		t.Errorf("stdout should be empty on failure, got %q", stdout)
	}
	golden(t, "error-validation.json", stderr)
}

func TestRunsCreateDerivesDefaults(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "runs", "create", "--date", "2026-09-01", "--json")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(stdout, `"runKey": "run-2026-09-01"`) {
		t.Errorf("derived run key missing:\n%s", stdout)
	}
	if !strings.Contains(stdout, `"usageCutoff": "2026-09-01T00:00:00Z"`) {
		t.Errorf("derived usage cutoff missing:\n%s", stdout)
	}
}

func TestExitCodeMapping(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()

	authSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusUnauthorized)
	}))
	defer authSrv.Close()

	cases := []struct {
		name string
		url  string
		args []string
		want int
	}{
		{"validation problem", srv.URL, []string{"subscriptions", "create", "--contract", "c", "--plan-version", "p", "--external-id", "x", "--start", "2026-09-01", "--quantity", "-1"}, ExitValidation},
		{"auth 401", authSrv.URL, []string{"status"}, ExitAuth},
		{"not found", srv.URL, []string{"customers", "get", "missing"}, ExitNotFound},
		{"idempotency conflict", srv.URL, []string{"invoices", "book", "ii-1"}, ExitConflict},
		{"unknown flag", srv.URL, []string{"status", "--nope"}, ExitUsage},
		{"unknown command", srv.URL, []string{"frobnicate"}, ExitUsage},
		{"missing required flag", srv.URL, []string{"invoices", "preview", "--as-of", "2026-09-01"}, ExitUsage},
		{"malformed date", srv.URL, []string{"invoices", "preview", "--subscription", "s", "--as-of", "September 1"}, ExitUsage},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, stderr, code := run(t, tc.url, tc.args...)
			if code != tc.want {
				t.Errorf("exit code = %d, want %d (stderr: %s)", code, tc.want, stderr)
			}
		})
	}
}

func TestMissingTeamIsUsageError(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	var out, errOut bytes.Buffer
	code := Execute([]string{"--url", srv.URL, "--token", "tok", "customers", "list"}, &out, &errOut, func(string) string { return "" })
	if code != ExitUsage {
		t.Fatalf("code = %d, want %d", code, ExitUsage)
	}
	if !strings.Contains(errOut.String(), "BILLING_TEAM") {
		t.Errorf("stderr should mention BILLING_TEAM: %s", errOut.String())
	}
}

func TestTransportFailureExitsSeven(t *testing.T) {
	// Unroutable port: connection refused on every attempt.
	_, stderr, code := run(t, "http://127.0.0.1:1", "status")
	if code != ExitTransport {
		t.Fatalf("code = %d, want %d (stderr: %s)", code, ExitTransport, stderr)
	}
	if !strings.Contains(stderr, "correlation-id: corr-fixed") {
		t.Errorf("stderr must print the correlation ID: %s", stderr)
	}
}

func TestCorrelationIDPrintedOnFailure(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	_, stderr, code := run(t, srv.URL, "customers", "get", "missing")
	if code != ExitNotFound {
		t.Fatalf("code = %d", code)
	}
	if !strings.Contains(stderr, "correlation-id: corr-fixed") {
		t.Errorf("stderr must print the correlation ID: %s", stderr)
	}
}

func TestEnvironmentFallbacks(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	env := map[string]string{
		"BILLING_URL":   srv.URL,
		"BILLING_TOKEN": "env-token",
		"BILLING_TEAM":  "team-1",
	}
	var out, errOut bytes.Buffer
	code := Execute([]string{"customers", "list", "--json"}, &out, &errOut, func(k string) string { return env[k] })
	if code != ExitOK {
		t.Fatalf("code = %d, stderr = %s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"schema": "billingctl.v1"`) {
		t.Errorf("envelope schema missing: %s", out.String())
	}
}

func TestDoctorHealthy(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	stdout, _, code := run(t, srv.URL, "doctor")
	if code != ExitOK {
		t.Fatalf("code = %d", code)
	}
	for _, want := range []string{"connectivity:  ok (apiVersion 2026-08-01)", "auth:          ok (viewer"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("doctor output missing %q:\n%s", want, stdout)
		}
	}
}

func TestDoctorWithoutTokenSkipsAuth(t *testing.T) {
	srv := stubServer(t)
	defer srv.Close()
	var out, errOut bytes.Buffer
	code := Execute([]string{"--url", srv.URL, "doctor"}, &out, &errOut, func(string) string { return "" })
	if code != ExitOK {
		t.Fatalf("code = %d, stderr = %s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "auth:          skipped (no token") {
		t.Errorf("doctor should skip auth without token:\n%s", out.String())
	}
}
