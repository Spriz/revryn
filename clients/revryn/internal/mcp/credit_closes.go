package mcpserver

import (
	"context"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

// Monthly customer-credit close tools (SPEC BC-US-163…165, BC-TASK-104).
// Reads are side-effect free; every consequential action requires explicit
// confirmation and carries idempotency/correlation references.

type listCreditClosesInput struct {
	teamScopedInput
	Currency string `json:"currency,omitempty" jsonschema:"Filter by ISO currency code."`
	State    string `json:"state,omitempty" jsonschema:"Filter by lifecycle state (open, ready, approved, posting, reconciled, closed, ...)."`
}

type listCreditClosesOutput struct {
	CreditCloses  []client.CreditClose `json:"creditCloses"`
	CorrelationID string               `json:"correlationId"`
}

type getCreditCloseInput struct {
	teamScopedInput
	CreditCloseID string `json:"credit_close_id" jsonschema:"Credit close UUID."`
}

type creditCloseOutput struct {
	CreditClose   *client.CreditClose `json:"creditClose"`
	CorrelationID string              `json:"correlationId"`
}

type listCreditClosePoliciesOutput struct {
	Policies      []client.CreditClosePolicy `json:"policies"`
	CorrelationID string                     `json:"correlationId"`
}

type getCreditCloseReportInput struct {
	teamScopedInput
	CreditCloseID string `json:"credit_close_id" jsonschema:"Credit close UUID."`
	EvidenceType  string `json:"evidence_type" jsonschema:"Evidence file type: canonical_json, csv_detail, pdf_summary, manifest, erp_voucher, erp_attachment, or reconciliation."`
}

type creditCloseReportOutput struct {
	Report        *client.CreditCloseReport `json:"report"`
	CorrelationID string                    `json:"correlationId"`
}

type createCreditClosePolicyInput struct {
	teamScopedInput
	EffectiveFrom              string `json:"effective_from" jsonschema:"First period start date the policy applies to (YYYY-MM-DD)."`
	JournalNumber              int    `json:"journal_number" jsonschema:"ERP journal number receiving the aggregate voucher."`
	LiabilityAccountNumber     int    `json:"liability_account_number" jsonschema:"General-ledger account carrying the customer-credit liability."`
	DefaultOffsetAccountNumber int    `json:"default_offset_account_number" jsonschema:"Single offset account for the balancing line."`
	PostZeroDelta              bool   `json:"post_zero_delta,omitempty" jsonschema:"Whether months with zero net change still post an ERP voucher."`
	SettlementMode             string `json:"settlement_mode,omitempty" jsonschema:"Receivable-settlement mode (SPEC 9.4.1): none (default, blocks automatic credit application), erp_customer_settlement, or external_reference."`
	SettlementClearingAccount  *int   `json:"settlement_clearing_account,omitempty" jsonschema:"Clearing account number; required for erp_customer_settlement."`
	SettlementContraAccount    *int   `json:"settlement_contra_account,omitempty" jsonschema:"Contra account number; required for erp_customer_settlement."`
	Confirm                    bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type creditClosePolicyOutput struct {
	Policy        *client.CreditClosePolicy `json:"policy"`
	CorrelationID string                    `json:"correlationId"`
}

type generateCreditCloseInput struct {
	teamScopedInput
	Currency              string `json:"currency" jsonschema:"ISO currency code of the close."`
	PeriodDate            string `json:"period_date" jsonschema:"Any date inside the close month (YYYY-MM-DD); the calendar month is frozen."`
	BootstrapOpeningMinor *int64 `json:"bootstrap_opening_minor,omitempty" jsonschema:"Opening balance in minor units — required only for the very first close of a currency (zero is valid)."`
	PolicyVersionID       string `json:"policy_version_id,omitempty" jsonschema:"Posting-policy version UUID; defaults to the latest."`
	IdempotencyKey        string `json:"idempotency_key,omitempty" jsonschema:"Stable key for exactly-once semantics (generated when absent)."`
	Confirm               bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type generateCreditCloseOutput struct {
	CreditClose    *client.CreditClose `json:"creditClose"`
	IdempotencyKey string              `json:"idempotencyKey"`
	CorrelationID  string              `json:"correlationId"`
}

type approveCreditCloseInput struct {
	teamScopedInput
	CreditCloseID string `json:"credit_close_id" jsonschema:"Credit close UUID (state must be ready)."`
	Reason        string `json:"reason,omitempty" jsonschema:"Approval reason recorded on the close."`
	Confirm       bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type postCreditCloseInput struct {
	teamScopedInput
	CreditCloseID  string `json:"credit_close_id" jsonschema:"Credit close UUID (state must be approved)."`
	IdempotencyKey string `json:"idempotency_key,omitempty" jsonschema:"Stable key for exactly-once semantics (generated when absent)."`
	Confirm        bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type postCreditCloseOutput struct {
	Operation      *client.Operation   `json:"operation"`
	CreditClose    *client.CreditClose `json:"creditClose"`
	IdempotencyKey string              `json:"idempotencyKey"`
	CorrelationID  string              `json:"correlationId"`
}

type acceptCreditClosePeriodInput struct {
	teamScopedInput
	CreditCloseID string `json:"credit_close_id" jsonschema:"Credit close UUID (state must be reconciled)."`
	Confirm       bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type reverseCreditCloseInput struct {
	teamScopedInput
	CreditCloseID string `json:"credit_close_id" jsonschema:"Accepted (closed) credit close UUID to reverse."`
	Reason        string `json:"reason" jsonschema:"Recorded correction reason for the audit trail."`
	Confirm       bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type replaceCreditCloseInput struct {
	teamScopedInput
	CreditCloseID   string `json:"credit_close_id" jsonschema:"Reversed credit close UUID whose period is being reposted."`
	PolicyVersionID string `json:"policy_version_id" jsonschema:"Corrected posting-policy version UUID."`
	Reason          string `json:"reason" jsonschema:"Recorded correction reason for the audit trail."`
	Confirm         bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

func (s *Server) registerCreditCloseTools() {
	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "list_credit_closes",
		Description: "Read-only. Lists the scoped team's monthly customer-credit closes, newest period first (max 100), with amounts, states, and evidence hashes. Requires team scope. No side effects.",
		Annotations: readOnly("List credit closes"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in listCreditClosesInput) (*sdk.CallToolResult, listCreditClosesOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, listCreditClosesOutput{}, err
		}
		closes, err := s.cl.CreditCloses(ctx, corr, team, in.Currency, in.State)
		if err != nil {
			return nil, listCreditClosesOutput{}, toolError(err, corr)
		}
		return nil, listCreditClosesOutput{CreditCloses: closes, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "get_credit_close",
		Description: "Read-only. Fetches one monthly close with movements, evidence hashes, and the posted voucher number when present. Requires team scope. No side effects.",
		Annotations: readOnly("Get credit close"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in getCreditCloseInput) (*sdk.CallToolResult, creditCloseOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditCloseOutput{}, err
		}
		close, err := s.cl.CreditClose(ctx, corr, team, in.CreditCloseID)
		if err != nil {
			return nil, creditCloseOutput{}, toolError(err, corr)
		}
		return nil, creditCloseOutput{CreditClose: close, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "list_credit_close_policies",
		Description: "Read-only. Lists the scoped team's close posting-policy versions, newest first. Requires team scope. No side effects.",
		Annotations: readOnly("List credit close policies"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in teamScopedInput) (*sdk.CallToolResult, listCreditClosePoliciesOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, listCreditClosePoliciesOutput{}, err
		}
		policies, err := s.cl.CreditClosePolicies(ctx, corr, team)
		if err != nil {
			return nil, listCreditClosePoliciesOutput{}, toolError(err, corr)
		}
		return nil, listCreditClosePoliciesOutput{Policies: policies, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "get_credit_close_report",
		Description: "Read-only. Fetches one immutable close evidence file with its exact bytes base64-encoded; the sha256 matches the close manifest. Requires team scope. No side effects.",
		Annotations: readOnly("Get credit close report"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in getCreditCloseReportInput) (*sdk.CallToolResult, creditCloseReportOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditCloseReportOutput{}, err
		}
		report, err := s.cl.CreditCloseReport(ctx, corr, team, in.CreditCloseID, in.EvidenceType)
		if err != nil {
			return nil, creditCloseReportOutput{}, toolError(err, corr)
		}
		return nil, creditCloseReportOutput{Report: report, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "create_credit_close_policy",
		Description: "MUTATING financial configuration. Creates a monthly-close posting-policy version (createCreditClosePolicy): the journal and accounts must be accountant-approved. Requires team scope and confirm=true.",
		Annotations: mutating("Create credit close policy"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in createCreditClosePolicyInput) (*sdk.CallToolResult, creditClosePolicyOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "create_credit_close_policy"); err != nil {
			return nil, creditClosePolicyOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditClosePolicyOutput{}, err
		}
		policy, err := s.cl.CreateCreditClosePolicy(ctx, corr, client.CreateCreditClosePolicyInput{
			TeamID:                     team,
			EffectiveFrom:              in.EffectiveFrom,
			JournalNumber:              in.JournalNumber,
			LiabilityAccountNumber:     in.LiabilityAccountNumber,
			DefaultOffsetAccountNumber: in.DefaultOffsetAccountNumber,
			PostZeroDelta:              in.PostZeroDelta,
			SettlementMode:             in.SettlementMode,
			SettlementClearingAccount:  in.SettlementClearingAccount,
			SettlementContraAccount:    in.SettlementContraAccount,
		})
		if err != nil {
			return nil, creditClosePolicyOutput{}, toolError(err, corr)
		}
		return nil, creditClosePolicyOutput{Policy: policy, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "generate_credit_close",
		Description: "MUTATING financial action. Freezes one deterministic close for a currency and calendar month (generateCreditClose) with immutable report evidence. Requires team scope and confirm=true; idempotent when the same idempotency_key is reused.",
		Annotations: mutating("Generate credit close"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in generateCreditCloseInput) (*sdk.CallToolResult, generateCreditCloseOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "generate_credit_close"); err != nil {
			return nil, generateCreditCloseOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, generateCreditCloseOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		close, err := s.cl.GenerateCreditClose(ctx, corr, client.GenerateCreditCloseInput{
			TeamID:                team,
			Currency:              in.Currency,
			PeriodDate:            in.PeriodDate,
			BootstrapOpeningMinor: in.BootstrapOpeningMinor,
			PolicyVersionID:       in.PolicyVersionID,
			IdempotencyKey:        key,
		})
		if err != nil {
			return nil, generateCreditCloseOutput{}, toolError(err, corr)
		}
		return nil, generateCreditCloseOutput{CreditClose: close, IdempotencyKey: key, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "approve_credit_close",
		Description: "MUTATING financial action. Approves the exact frozen report hash of a ready close for ERP posting (approveCreditClose). Requires team scope and confirm=true. The upstream contract defines no idempotency key for approval.",
		Annotations: mutating("Approve credit close"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in approveCreditCloseInput) (*sdk.CallToolResult, creditCloseOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "approve_credit_close"); err != nil {
			return nil, creditCloseOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditCloseOutput{}, err
		}
		close, err := s.cl.ApproveCreditClose(ctx, corr, client.ApproveCreditCloseInput{
			TeamID:        team,
			CreditCloseID: in.CreditCloseID,
			Reason:        in.Reason,
		})
		if err != nil {
			return nil, creditCloseOutput{}, toolError(err, corr)
		}
		return nil, creditCloseOutput{CreditClose: close, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "post_credit_close",
		Description: "MUTATING financial action. Creates the durable, idempotent ERP posting operation for an approved close (requestCreditClosePosting) — this creates accounting records. The provider is searched by stable reference before any create; no duplicate voucher is possible. Requires team scope and confirm=true. Asynchronous: follow the returned operation with get_operation.",
		Annotations: mutating("Post credit close"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in postCreditCloseInput) (*sdk.CallToolResult, postCreditCloseOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "post_credit_close"); err != nil {
			return nil, postCreditCloseOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, postCreditCloseOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		posting, err := s.cl.RequestCreditClosePosting(ctx, corr, client.RequestCreditClosePostingInput{
			TeamID:         team,
			CreditCloseID:  in.CreditCloseID,
			IdempotencyKey: key,
		})
		if err != nil {
			return nil, postCreditCloseOutput{}, toolError(err, corr)
		}
		return nil, postCreditCloseOutput{
			Operation:      posting.Operation,
			CreditClose:    posting.CreditClose,
			IdempotencyKey: key,
			CorrelationID:  corr,
		}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "reverse_credit_close",
		Description: "MUTATING financial action. Freezes a compensating reversal close for an accepted close (requestCreditCloseReversal, ADR-031): the mirrored bridge whose voucher cancels the original in the general ledger. The reversal must then be approved and posted; the original becomes reversed when it reconciles. Requires team scope, a recorded reason, and confirm=true.",
		Annotations: mutating("Reverse credit close"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in reverseCreditCloseInput) (*sdk.CallToolResult, creditCloseOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "reverse_credit_close"); err != nil {
			return nil, creditCloseOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditCloseOutput{}, err
		}
		close, err := s.cl.RequestCreditCloseReversal(ctx, corr, client.RequestCreditCloseReversalInput{
			TeamID:        team,
			CreditCloseID: in.CreditCloseID,
			Reason:        in.Reason,
		})
		if err != nil {
			return nil, creditCloseOutput{}, toolError(err, corr)
		}
		return nil, creditCloseOutput{CreditClose: close, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "replace_credit_close",
		Description: "MUTATING financial action. Freezes a replacement close for a reversed period under a corrected policy (generateCreditCloseReplacement, ADR-031), reproducing the exact frozen figures hash-verified from the immutable membership. Requires team scope, a recorded reason, and confirm=true.",
		Annotations: mutating("Replace credit close"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in replaceCreditCloseInput) (*sdk.CallToolResult, creditCloseOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "replace_credit_close"); err != nil {
			return nil, creditCloseOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditCloseOutput{}, err
		}
		close, err := s.cl.GenerateCreditCloseReplacement(ctx, corr, client.GenerateCreditCloseReplacementInput{
			TeamID:          team,
			CreditCloseID:   in.CreditCloseID,
			PolicyVersionID: in.PolicyVersionID,
			Reason:          in.Reason,
		})
		if err != nil {
			return nil, creditCloseOutput{}, toolError(err, corr)
		}
		return nil, creditCloseOutput{CreditClose: close, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "accept_credit_close_period",
		Description: "MUTATING financial action. Accepts a fully reconciled close as the authoritative period close (closeCreditPeriod). Corrections after acceptance happen in later periods, never by edits. Requires team scope and confirm=true.",
		Annotations: mutating("Accept credit close period"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in acceptCreditClosePeriodInput) (*sdk.CallToolResult, creditCloseOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "accept_credit_close_period"); err != nil {
			return nil, creditCloseOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, creditCloseOutput{}, err
		}
		close, err := s.cl.CloseCreditPeriod(ctx, corr, client.CloseCreditPeriodInput{
			TeamID:        team,
			CreditCloseID: in.CreditCloseID,
		})
		if err != nil {
			return nil, creditCloseOutput{}, toolError(err, corr)
		}
		return nil, creditCloseOutput{CreditClose: close, CorrelationID: corr}, nil
	})
}
