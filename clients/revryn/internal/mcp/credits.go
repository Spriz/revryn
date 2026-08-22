package mcpserver

import (
	"context"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

// Customer-credit subledger tools (SPEC BC-US-107…109, §9.4.1). Credit is
// money-like settlement value, never a discount (INV-050); settlements
// clear credit-covered receivables exactly once.

type listCreditAccountsInput struct {
	teamScopedInput
	CustomerID string `json:"customer_id" jsonschema:"Customer UUID whose linked credit accounts to list."`
}

type listCreditAccountsOutput struct {
	CreditAccounts []client.CreditAccount `json:"creditAccounts"`
	CorrelationID  string                 `json:"correlationId"`
}

type listCreditSettlementsInput struct {
	teamScopedInput
	InvoiceIntentID string `json:"invoice_intent_id,omitempty" jsonschema:"Filter by invoice intent UUID."`
	State           string `json:"state,omitempty" jsonschema:"Filter by state: pending or reconciled."`
}

type listCreditSettlementsOutput struct {
	CreditSettlements []client.CreditSettlement `json:"creditSettlements"`
	CorrelationID     string                    `json:"correlationId"`
}

type grantCreditInput struct {
	teamScopedInput
	CreditAccountID string `json:"credit_account_id" jsonschema:"Credit account UUID receiving the grant."`
	OriginType      string `json:"origin_type" jsonschema:"unused_prepaid_service, goodwill, external_correction, or manual."`
	AmountMinor     int64  `json:"amount_minor" jsonschema:"Amount in integer minor units; must be positive."`
	Currency        string `json:"currency" jsonschema:"ISO currency code; must match the account currency (INV-052)."`
	ReasonCode      string `json:"reason_code,omitempty" jsonschema:"Optional reason code for the audit trail."`
	IdempotencyKey  string `json:"idempotency_key,omitempty" jsonschema:"Stable retry key; auto-generated when omitted."`
	Confirm         bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type grantCreditOutput struct {
	CreditGrant    *client.CreditGrant `json:"creditGrant"`
	IdempotencyKey string              `json:"idempotencyKey"`
	CorrelationID  string              `json:"correlationId"`
}

type setCreditDispositionPolicyInput struct {
	teamScopedInput
	CreditAccountID string `json:"credit_account_id" jsonschema:"Credit account UUID the policy applies to."`
	Policy          string `json:"policy" jsonschema:"retain, refund, or expire_after."`
	ExpireAfterDays *int   `json:"expire_after_days,omitempty" jsonschema:"Required for expire_after: days until unused credit expires."`
	Confirm         bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type setCreditDispositionPolicyOutput struct {
	DispositionPolicy *client.CreditDispositionPolicy `json:"dispositionPolicy"`
	CorrelationID     string                          `json:"correlationId"`
}

type recordExternalSettlementInput struct {
	teamScopedInput
	SettlementID      string `json:"settlement_id" jsonschema:"Settlement UUID to reconcile (list_credit_settlements shows pending ones)."`
	ExternalReference string `json:"external_reference" jsonschema:"The authoritative external receivables system's settlement reference."`
	Confirm           bool   `json:"confirm" jsonschema:"Explicit confirmation. Must be true; consequential financial actions are never executed on model intent alone."`
}

type recordExternalSettlementOutput struct {
	Settlement    *client.CreditSettlement `json:"settlement"`
	CorrelationID string                   `json:"correlationId"`
}

func (s *Server) registerCreditTools() {
	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "list_credit_accounts",
		Description: "Read-only. Lists a customer's team-scoped credit accounts with balances, grants, append-only transactions, and the current disposition policy. Requires team scope. No side effects.",
		Annotations: readOnly("List credit accounts"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in listCreditAccountsInput) (*sdk.CallToolResult, listCreditAccountsOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, listCreditAccountsOutput{}, err
		}
		accounts, err := s.cl.CreditAccounts(ctx, corr, team, in.CustomerID)
		if err != nil {
			return nil, listCreditAccountsOutput{}, toolError(err, corr)
		}
		return nil, listCreditAccountsOutput{CreditAccounts: accounts, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "list_credit_settlements",
		Description: "Read-only. Lists receivable settlements opened by credit applications (SPEC §9.4.1), newest first, with mode, state, and reconciliation evidence. Requires team scope. No side effects.",
		Annotations: readOnly("List credit settlements"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in listCreditSettlementsInput) (*sdk.CallToolResult, listCreditSettlementsOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, listCreditSettlementsOutput{}, err
		}
		settlements, err := s.cl.CreditSettlements(ctx, corr, team, in.InvoiceIntentID, in.State)
		if err != nil {
			return nil, listCreditSettlementsOutput{}, toolError(err, corr)
		}
		return nil, listCreditSettlementsOutput{CreditSettlements: settlements, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "grant_credit",
		Description: "MUTATING financial action. Grants customer credit into the subledger — a liability, never a discount (grantCredit, BC-US-107). Requires team scope and confirm=true; idempotent when the same idempotency_key is reused.",
		Annotations: mutating("Grant credit"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in grantCreditInput) (*sdk.CallToolResult, grantCreditOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "grant_credit"); err != nil {
			return nil, grantCreditOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, grantCreditOutput{}, err
		}
		key := in.IdempotencyKey
		if key == "" {
			key = client.NewIdempotencyKey()
		}
		grant, err := s.cl.GrantCredit(ctx, corr, client.GrantCreditInput{
			TeamID:          team,
			CreditAccountID: in.CreditAccountID,
			OriginType:      in.OriginType,
			AmountMinor:     in.AmountMinor,
			Currency:        in.Currency,
			ReasonCode:      in.ReasonCode,
			IdempotencyKey:  key,
		})
		if err != nil {
			return nil, grantCreditOutput{}, toolError(err, corr)
		}
		return nil, grantCreditOutput{CreditGrant: grant, IdempotencyKey: key, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "set_credit_disposition_policy",
		Description: "MUTATING financial configuration. Sets the versioned remaining-credit disposition policy — retain, refund, or expire_after (setCreditDispositionPolicy, BC-US-109). Requires team scope and confirm=true.",
		Annotations: mutating("Set credit disposition policy"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in setCreditDispositionPolicyInput) (*sdk.CallToolResult, setCreditDispositionPolicyOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "set_credit_disposition_policy"); err != nil {
			return nil, setCreditDispositionPolicyOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, setCreditDispositionPolicyOutput{}, err
		}
		policy, err := s.cl.SetCreditDispositionPolicy(ctx, corr, client.SetCreditDispositionPolicyInput{
			TeamID:          team,
			CreditAccountID: in.CreditAccountID,
			Policy:          in.Policy,
			ExpireAfterDays: in.ExpireAfterDays,
		})
		if err != nil {
			return nil, setCreditDispositionPolicyOutput{}, toolError(err, corr)
		}
		return nil, setCreditDispositionPolicyOutput{DispositionPolicy: policy, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "record_external_settlement",
		Description: "MUTATING financial action. Records the authoritative external receivables system's settlement reference for one pending settlement, reconciling it exactly once (recordExternalSettlement, SPEC §9.4.1). Requires team scope and confirm=true.",
		Annotations: mutating("Record external settlement"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in recordExternalSettlementInput) (*sdk.CallToolResult, recordExternalSettlementOutput, error) {
		corr := client.NewCorrelationID()
		if err := requireConfirm(in.Confirm, "record_external_settlement"); err != nil {
			return nil, recordExternalSettlementOutput{}, err
		}
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, recordExternalSettlementOutput{}, err
		}
		settlement, err := s.cl.RecordExternalSettlement(ctx, corr, client.RecordExternalSettlementInput{
			TeamID:            team,
			SettlementID:      in.SettlementID,
			ExternalReference: in.ExternalReference,
		})
		if err != nil {
			return nil, recordExternalSettlementOutput{}, toolError(err, corr)
		}
		return nil, recordExternalSettlementOutput{Settlement: settlement, CorrelationID: corr}, nil
	})
}
