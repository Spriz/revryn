package mcpserver

import (
	"context"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/revryn/billing-core/internal/client"
)

// mutating annotates a consequential financial tool. All Billing Core
// mutations are additive (append-only financial records), never destructive.
// IdempotentHint stays false because omitting idempotency_key generates a
// fresh key per call; callers that pass an explicit key get safe retries.
func mutating(title string) *sdk.ToolAnnotations {
	return &sdk.ToolAnnotations{
		Title:           title,
		ReadOnlyHint:    false,
		DestructiveHint: ptr(false),
		IdempotentHint:  false,
	}
}

type freezeInvoiceInput struct {
	teamScopedInput
	SubscriptionID string `json:"subscription_id" jsonschema:"Subscription UUID whose current preview will be frozen."`
	AsOf           string `json:"as_of" jsonschema:"Preview date (YYYY-MM-DD); the billing period containing it is frozen."`
	BillingRunID   string `json:"billing_run_id,omitempty" jsonschema:"Optional billing run UUID to attach the intent to."`
	IdempotencyKey string `json:"idempotency_key,omitempty" jsonschema:"Idempotency key. Auto-generated UUID when omitted; pass the same key to retry safely."`
	Confirm        bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type freezeInvoiceOutput struct {
	InvoiceIntent  *client.InvoiceIntent `json:"invoiceIntent"`
	IdempotencyKey string                `json:"idempotencyKey"`
	CorrelationID  string                `json:"correlationId"`
}

type synchronizeInvoiceInput struct {
	teamScopedInput
	InvoiceIntentID string `json:"invoice_intent_id" jsonschema:"Frozen invoice intent UUID to synchronize into the ERP as a draft."`
	IdempotencyKey  string `json:"idempotency_key,omitempty" jsonschema:"Idempotency key. Auto-generated UUID when omitted; pass the same key to retry safely."`
	Confirm         bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type asyncOperationOutput struct {
	Operation      *client.Operation `json:"operation"`
	IdempotencyKey string            `json:"idempotencyKey,omitempty"`
	CorrelationID  string            `json:"correlationId"`
}

type approveInvoiceInput struct {
	teamScopedInput
	InvoiceIntentID string `json:"invoice_intent_id" jsonschema:"Reconciled ERP-draft invoice intent UUID to approve for booking."`
	Reason          string `json:"reason,omitempty" jsonschema:"Optional approval reason recorded in the audit trail."`
	Confirm         bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type approveInvoiceOutput struct {
	InvoiceIntent *client.InvoiceIntent `json:"invoiceIntent"`
	CorrelationID string                `json:"correlationId"`
}

type bookInvoiceInput struct {
	teamScopedInput
	InvoiceIntentID string `json:"invoice_intent_id" jsonschema:"Approved invoice intent UUID to book in the ERP."`
	IdempotencyKey  string `json:"idempotency_key,omitempty" jsonschema:"Idempotency key. Auto-generated UUID when omitted; pass the same key to retry safely."`
	Confirm         bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type retryOperationInput struct {
	teamScopedInput
	OperationID string `json:"operation_id" jsonschema:"Failed durable operation UUID to retry."`
	Confirm     bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type createBillingRunInput struct {
	teamScopedInput
	InvoiceDate    string `json:"invoice_date" jsonschema:"Invoice date (YYYY-MM-DD) for the run."`
	RunKey         string `json:"run_key,omitempty" jsonschema:"Stable run key; defaults to run-<invoice_date>. Reopening the same key returns the existing run."`
	UsageCutoff    string `json:"usage_cutoff,omitempty" jsonschema:"Usage cutoff as ISO 8601 UTC timestamp; defaults to <invoice_date>T00:00:00Z."`
	IdempotencyKey string `json:"idempotency_key,omitempty" jsonschema:"Idempotency key. Auto-generated UUID when omitted; pass the same key to retry safely."`
	Confirm        bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type billingRunOutput struct {
	BillingRun     *client.BillingRun `json:"billingRun"`
	IdempotencyKey string             `json:"idempotencyKey"`
	CorrelationID  string             `json:"correlationId"`
}

func (s *Server) registerMutatingTools() {
	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "freeze_invoice",
		Description: "MUTATING financial action. Freezes a subscription's deterministic preview into an immutable invoice intent (freezeInvoiceIntent). Requires team scope and confirm=true; idempotent when the same idempotency_key is reused. Returns the intent and correlation reference.",
		Annotations: mutating("Freeze invoice intent"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in freezeInvoiceInput) (*sdk.CallToolResult, freezeInvoiceOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "freeze_invoice"); err != nil {
			return nil, freezeInvoiceOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, freezeInvoiceOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		intent, err := s.cl.FreezeInvoiceIntent(ctx, corr, client.FreezeInvoiceIntentInput{
			TeamID:         team,
			SubscriptionID: in.SubscriptionID,
			AsOf:           in.AsOf,
			BillingRunID:   in.BillingRunID,
			IdempotencyKey: key,
		})
		if err != nil {
			return nil, freezeInvoiceOutput{}, toolError(err, corr)
		}
		return nil, freezeInvoiceOutput{InvoiceIntent: intent, IdempotencyKey: key, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "synchronize_invoice",
		Description: "MUTATING financial action. Enqueues ERP draft synchronization for a frozen invoice intent (synchronizeInvoice). Requires team scope and confirm=true. Asynchronous: returns the durable operation to follow with get_operation, plus idempotency and correlation references.",
		Annotations: mutating("Synchronize invoice to ERP"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in synchronizeInvoiceInput) (*sdk.CallToolResult, asyncOperationOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "synchronize_invoice"); err != nil {
			return nil, asyncOperationOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, asyncOperationOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		op, err := s.cl.SynchronizeInvoice(ctx, corr, client.SynchronizeInvoiceInput{
			TeamID:          team,
			InvoiceIntentID: in.InvoiceIntentID,
			IdempotencyKey:  key,
		})
		if err != nil {
			return nil, asyncOperationOutput{}, toolError(err, corr)
		}
		return nil, asyncOperationOutput{Operation: op, IdempotencyKey: key, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "approve_invoice",
		Description: "MUTATING financial action. Approves a reconciled ERP draft for booking (approveInvoice). Requires team scope and confirm=true. The upstream contract defines no idempotency key for approval; approving an already-approved intent yields a validation problem.",
		Annotations: mutating("Approve invoice"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in approveInvoiceInput) (*sdk.CallToolResult, approveInvoiceOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "approve_invoice"); err != nil {
			return nil, approveInvoiceOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, approveInvoiceOutput{}, err
		}
		intent, err := s.cl.ApproveInvoice(ctx, corr, client.ApproveInvoiceInput{
			TeamID:          team,
			InvoiceIntentID: in.InvoiceIntentID,
			Reason:          in.Reason,
		})
		if err != nil {
			return nil, approveInvoiceOutput{}, toolError(err, corr)
		}
		return nil, approveInvoiceOutput{InvoiceIntent: intent, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "book_invoice",
		Description: "MUTATING financial action. Enqueues booking of an approved ERP draft (bookInvoice) — this creates accounting records. Requires team scope and confirm=true. Asynchronous: returns the durable operation to follow with get_operation, plus idempotency and correlation references.",
		Annotations: mutating("Book invoice"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in bookInvoiceInput) (*sdk.CallToolResult, asyncOperationOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "book_invoice"); err != nil {
			return nil, asyncOperationOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, asyncOperationOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		op, err := s.cl.BookInvoice(ctx, corr, client.BookInvoiceInput{
			TeamID:          team,
			InvoiceIntentID: in.InvoiceIntentID,
			IdempotencyKey:  key,
		})
		if err != nil {
			return nil, asyncOperationOutput{}, toolError(err, corr)
		}
		return nil, asyncOperationOutput{Operation: op, IdempotencyKey: key, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "retry_operation",
		Description: "MUTATING action. Manually retries a failed durable operation (retryOperation; finance role). Requires team scope and confirm=true. The upstream contract defines no idempotency key for retry; the server guards duplicate retries.",
		Annotations: mutating("Retry operation"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in retryOperationInput) (*sdk.CallToolResult, asyncOperationOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "retry_operation"); err != nil {
			return nil, asyncOperationOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, asyncOperationOutput{}, err
		}
		op, err := s.cl.RetryOperation(ctx, corr, client.RetryOperationInput{
			TeamID:      team,
			OperationID: in.OperationID,
		})
		if err != nil {
			return nil, asyncOperationOutput{}, toolError(err, corr)
		}
		return nil, asyncOperationOutput{Operation: op, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "create_billing_run",
		Description: "MUTATING financial action. Opens (or returns) a billing run by stable run key (createBillingRun). Requires team scope and confirm=true. Reopening an existing run key returns the existing run; idempotent when the same idempotency_key is reused.",
		Annotations: mutating("Create billing run"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in createBillingRunInput) (*sdk.CallToolResult, billingRunOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "create_billing_run"); err != nil {
			return nil, billingRunOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, billingRunOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		runKey := in.RunKey
		if runKey == "" {
			runKey = "run-" + in.InvoiceDate
		}
		cutoff := in.UsageCutoff
		if cutoff == "" {
			cutoff = in.InvoiceDate + "T00:00:00Z"
		}
		run, err := s.cl.CreateBillingRun(ctx, corr, client.CreateBillingRunInput{
			TeamID:         team,
			RunKey:         runKey,
			InvoiceDate:    in.InvoiceDate,
			UsageCutoff:    cutoff,
			IdempotencyKey: key,
		})
		if err != nil {
			return nil, billingRunOutput{}, toolError(err, corr)
		}
		return nil, billingRunOutput{BillingRun: run, IdempotencyKey: key, CorrelationID: corr}, nil
	})
}
