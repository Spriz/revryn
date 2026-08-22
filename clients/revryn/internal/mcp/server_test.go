package mcpserver

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

// stubUpstream is a minimal Billing Core GraphQL stub.
func stubUpstream(t *testing.T) (*httptest.Server, *atomic.Int32, *atomic.Value) {
	t.Helper()
	var mutations atomic.Int32
	var lastInput atomic.Value // map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Query     string         `json:"query"`
			Variables map[string]any `json:"variables"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		write := func(data string) { w.Write([]byte(`{"data":` + data + `}`)) }
		switch {
		case strings.Contains(body.Query, "RevrynStatus"):
			write(`{"apiVersion":"2026-08-01","viewer":{"id":"v-1","status":"active","platformAdmin":false,
				"organizationMemberships":[],"teamMemberships":[]}}`)
		case strings.Contains(body.Query, "RevrynCustomers"):
			write(`{"customers":{"edges":[{"cursor":"c1","node":{"id":"cu-1","externalId":"crm-1","status":"active","currentVersion":1,"legalName":"Acme"}}],"pageInfo":{"hasNextPage":false,"endCursor":"c1"}}}`)
		case strings.Contains(body.Query, "RevrynFreezeInvoiceIntent"):
			mutations.Add(1)
			if input, ok := body.Variables["input"].(map[string]any); ok {
				lastInput.Store(input)
			}
			write(`{"freezeInvoiceIntent":{"__typename":"FreezeInvoiceIntentSuccess","invoiceIntent":{
				"id":"ii-1","state":"frozen","customerId":"cu-1","customerVersion":1,"currency":"DKK",
				"invoiceDate":"2026-09-01","intentVersion":1,"documentKind":"invoice","contentHash":"h",
				"netAmountMinor":250000,"frozenAt":"2026-08-21T10:00:00Z","lines":[]}}}`)
		case strings.Contains(body.Query, "RevrynGenerateCreditClose"):
			mutations.Add(1)
			if input, ok := body.Variables["input"].(map[string]any); ok {
				lastInput.Store(input)
			}
			write(`{"generateCreditClose":{"__typename":"GenerateCreditCloseSuccess","creditClose":{
				"id":"cc-1","state":"ready","currency":"DKK","periodStart":"2026-08-01","periodEndExclusive":"2026-09-01",
				"transactionCutoff":"2026-08-22T10:00:00Z","openingMinor":0,"closingMinor":9000,"netChangeMinor":9000,
				"economicLiabilityLineMinor":-9000,"ledgerTransactionCount":1,"reportSha256":"cccc3333","closedAt":null,
				"externalVoucherNumber":null,"movements":[],"evidence":[]}}}`)
		default:
			t.Errorf("stub received unexpected query: %s", body.Query)
			write(`null`)
		}
	}))
	return srv, &mutations, &lastInput
}

// session connects an in-memory MCP client to a server built with cfg.
func session(t *testing.T, cfg Config) *sdk.ClientSession {
	t.Helper()
	if cfg.Version == "" {
		cfg.Version = "test"
	}
	srv := New(cfg)
	serverTransport, clientTransport := sdk.NewInMemoryTransports()
	ctx := context.Background()
	serverSession, err := srv.MCP().Connect(ctx, serverTransport, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })
	cli := sdk.NewClient(&sdk.Implementation{Name: "revryn-test", Version: "test"}, nil)
	clientSession, err := cli.Connect(ctx, clientTransport, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = clientSession.Close() })
	return clientSession
}

var readTools = []string{
	"billing_status", "list_customers", "get_customer", "list_subscriptions",
	"get_subscription", "preview_invoice", "get_invoice", "get_operation",
	"list_credit_closes", "get_credit_close", "list_credit_close_policies",
	"get_credit_close_report", "list_credit_accounts", "list_credit_settlements",
}

var mutatingTools = []string{
	"freeze_invoice", "synchronize_invoice", "approve_invoice", "book_invoice",
	"retry_operation", "create_billing_run",
	"create_credit_close_policy", "generate_credit_close", "approve_credit_close",
	"post_credit_close", "accept_credit_close_period",
	"reverse_credit_close", "replace_credit_close",
	"grant_credit", "set_credit_disposition_policy", "record_external_settlement",
}

func TestToolListingAndAnnotations(t *testing.T) {
	upstream, _, _ := stubUpstream(t)
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "tok", TeamID: "team-1"})

	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("ListTools: %v", err)
	}
	byName := map[string]*sdk.Tool{}
	for _, tool := range res.Tools {
		byName[tool.Name] = tool
	}
	if len(byName) != len(readTools)+len(mutatingTools) {
		t.Errorf("tool count = %d, want %d", len(byName), len(readTools)+len(mutatingTools))
	}
	for _, name := range readTools {
		tool := byName[name]
		if tool == nil {
			t.Errorf("read tool %q missing", name)
			continue
		}
		if tool.Annotations == nil || !tool.Annotations.ReadOnlyHint {
			t.Errorf("tool %q must carry readOnlyHint=true", name)
		}
		if tool.InputSchema == nil {
			t.Errorf("tool %q has no input schema", name)
		}
		if tool.OutputSchema == nil {
			t.Errorf("tool %q has no output schema", name)
		}
	}
	for _, name := range mutatingTools {
		tool := byName[name]
		if tool == nil {
			t.Errorf("mutating tool %q missing", name)
			continue
		}
		if tool.Annotations == nil || tool.Annotations.ReadOnlyHint {
			t.Errorf("tool %q must carry readOnlyHint=false", name)
		}
		// confirm must be a required schema property.
		schemaJSON, err := json.Marshal(tool.InputSchema)
		if err != nil {
			t.Fatalf("marshal input schema: %v", err)
		}
		var schema struct {
			Properties map[string]any `json:"properties"`
			Required   []string       `json:"required"`
		}
		if err := json.Unmarshal(schemaJSON, &schema); err != nil {
			t.Fatalf("decode input schema: %v", err)
		}
		if _, ok := schema.Properties["confirm"]; !ok {
			t.Errorf("tool %q input schema lacks confirm property", name)
		}
		found := false
		for _, req := range schema.Required {
			if req == "confirm" {
				found = true
			}
		}
		if !found {
			t.Errorf("tool %q must require confirm; required=%v", name, schema.Required)
		}
	}
}

func TestBillingStatusReadTool(t *testing.T) {
	upstream, _, _ := stubUpstream(t)
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "tok"})

	res, err := cs.CallTool(context.Background(), &sdk.CallToolParams{Name: "billing_status", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("billing_status errored: %+v", res.Content)
	}
	out, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		APIVersion    string `json:"apiVersion"`
		CorrelationID string `json:"correlationId"`
	}
	if err := json.Unmarshal(out, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.APIVersion != "2026-08-01" {
		t.Errorf("apiVersion = %q", decoded.APIVersion)
	}
	if decoded.CorrelationID == "" {
		t.Error("correlationId missing from tool output")
	}
}

func TestListCustomersUsesServerTeamScope(t *testing.T) {
	upstream, _, _ := stubUpstream(t)
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "tok", TeamID: "team-default"})

	res, err := cs.CallTool(context.Background(), &sdk.CallToolParams{Name: "list_customers", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if res.IsError {
		t.Fatalf("list_customers errored: %+v", res.Content)
	}
}

func TestTeamScopeRequired(t *testing.T) {
	upstream, _, _ := stubUpstream(t)
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "tok"}) // no default team

	res, err := cs.CallTool(context.Background(), &sdk.CallToolParams{Name: "list_customers", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if !res.IsError {
		t.Fatal("list_customers without team scope must fail")
	}
	if !strings.Contains(contentText(res), "team scope required") {
		t.Errorf("error should explain team scope: %+v", res.Content)
	}
}

func TestFreezeInvoiceConfirmGating(t *testing.T) {
	upstream, mutations, lastInput := stubUpstream(t)
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "tok", TeamID: "team-1"})
	ctx := context.Background()

	t.Run("confirm false is rejected before any upstream call", func(t *testing.T) {
		res, err := cs.CallTool(ctx, &sdk.CallToolParams{Name: "freeze_invoice", Arguments: map[string]any{
			"subscription_id": "sub-1", "as_of": "2026-09-01", "confirm": false,
		}})
		if err != nil {
			t.Fatalf("CallTool: %v", err)
		}
		if !res.IsError {
			t.Fatal("freeze_invoice with confirm=false must fail")
		}
		if !strings.Contains(contentText(res), "confirmation required") {
			t.Errorf("error should demand confirmation: %+v", res.Content)
		}
		if mutations.Load() != 0 {
			t.Errorf("upstream mutation ran despite missing confirmation")
		}
	})

	t.Run("confirm missing is rejected by the input schema", func(t *testing.T) {
		res, err := cs.CallTool(ctx, &sdk.CallToolParams{Name: "freeze_invoice", Arguments: map[string]any{
			"subscription_id": "sub-1", "as_of": "2026-09-01",
		}})
		if err == nil && !res.IsError {
			t.Fatal("freeze_invoice without confirm must fail")
		}
		if mutations.Load() != 0 {
			t.Errorf("upstream mutation ran despite missing confirmation")
		}
	})

	t.Run("confirm true executes and returns references", func(t *testing.T) {
		res, err := cs.CallTool(ctx, &sdk.CallToolParams{Name: "freeze_invoice", Arguments: map[string]any{
			"subscription_id": "sub-1", "as_of": "2026-09-01", "confirm": true, "idempotency_key": "fixed-key",
		}})
		if err != nil {
			t.Fatalf("CallTool: %v", err)
		}
		if res.IsError {
			t.Fatalf("freeze_invoice errored: %+v", contentText(res))
		}
		if mutations.Load() != 1 {
			t.Errorf("upstream mutations = %d, want 1", mutations.Load())
		}
		input, _ := lastInput.Load().(map[string]any)
		if input["teamId"] != "team-1" {
			t.Errorf("upstream teamId = %v, want server default team-1", input["teamId"])
		}
		if input["idempotencyKey"] != "fixed-key" {
			t.Errorf("upstream idempotencyKey = %v, want fixed-key", input["idempotencyKey"])
		}
		out, _ := json.Marshal(res.StructuredContent)
		var decoded struct {
			IdempotencyKey string `json:"idempotencyKey"`
			CorrelationID  string `json:"correlationId"`
			InvoiceIntent  struct {
				ID    string `json:"id"`
				State string `json:"state"`
			} `json:"invoiceIntent"`
		}
		if err := json.Unmarshal(out, &decoded); err != nil {
			t.Fatal(err)
		}
		if decoded.InvoiceIntent.ID != "ii-1" || decoded.InvoiceIntent.State != "frozen" {
			t.Errorf("unexpected intent: %+v", decoded.InvoiceIntent)
		}
		if decoded.IdempotencyKey != "fixed-key" || decoded.CorrelationID == "" {
			t.Errorf("missing idempotency/correlation references: %+v", decoded)
		}
	})
}

func TestGenerateCreditCloseConfirmGating(t *testing.T) {
	upstream, mutations, lastInput := stubUpstream(t)
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "tok", TeamID: "team-1"})
	ctx := context.Background()

	t.Run("confirm false is rejected before any upstream call", func(t *testing.T) {
		res, err := cs.CallTool(ctx, &sdk.CallToolParams{Name: "generate_credit_close", Arguments: map[string]any{
			"currency": "DKK", "period_date": "2026-08-15", "confirm": false,
		}})
		if err != nil {
			t.Fatalf("CallTool: %v", err)
		}
		if !res.IsError {
			t.Fatal("generate_credit_close with confirm=false must fail")
		}
		if mutations.Load() != 0 {
			t.Errorf("upstream mutation ran despite missing confirmation")
		}
	})

	t.Run("confirm true executes with idempotency and correlation references", func(t *testing.T) {
		res, err := cs.CallTool(ctx, &sdk.CallToolParams{Name: "generate_credit_close", Arguments: map[string]any{
			"currency": "DKK", "period_date": "2026-08-15", "confirm": true, "idempotency_key": "close-key",
		}})
		if err != nil {
			t.Fatalf("CallTool: %v", err)
		}
		if res.IsError {
			t.Fatalf("generate_credit_close errored: %+v", contentText(res))
		}
		if mutations.Load() != 1 {
			t.Errorf("upstream mutations = %d, want 1", mutations.Load())
		}
		input, _ := lastInput.Load().(map[string]any)
		if input["teamId"] != "team-1" || input["idempotencyKey"] != "close-key" {
			t.Errorf("unexpected upstream input: %+v", input)
		}
		out, _ := json.Marshal(res.StructuredContent)
		var decoded struct {
			IdempotencyKey string `json:"idempotencyKey"`
			CorrelationID  string `json:"correlationId"`
			CreditClose    struct {
				ID    string `json:"id"`
				State string `json:"state"`
			} `json:"creditClose"`
		}
		if err := json.Unmarshal(out, &decoded); err != nil {
			t.Fatal(err)
		}
		if decoded.CreditClose.ID != "cc-1" || decoded.CreditClose.State != "ready" {
			t.Errorf("unexpected close: %+v", decoded.CreditClose)
		}
		if decoded.IdempotencyKey != "close-key" || decoded.CorrelationID == "" {
			t.Errorf("missing idempotency/correlation references: %+v", decoded)
		}
	})
}

func TestUpstreamAuthFailureIsSafeToolError(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "secret internal detail", http.StatusUnauthorized)
	}))
	defer upstream.Close()
	cs := session(t, Config{BaseURL: upstream.URL, Token: "bad", TeamID: "team-1"})

	res, err := cs.CallTool(context.Background(), &sdk.CallToolParams{Name: "billing_status", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	if !res.IsError {
		t.Fatal("expected tool error")
	}
	text := contentText(res)
	if !strings.Contains(text, "authentication or authorization failed") {
		t.Errorf("unsafe or unclear error message: %q", text)
	}
	if strings.Contains(text, "secret internal detail") {
		t.Errorf("upstream body leaked into tool error: %q", text)
	}
	if !strings.Contains(text, "correlation-id:") {
		t.Errorf("tool error must carry a correlation reference: %q", text)
	}
}

func contentText(res *sdk.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*sdk.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String()
}
