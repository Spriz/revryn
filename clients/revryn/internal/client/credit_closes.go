package client

import (
	"context"
	"encoding/base64"
	"fmt"
)

// Monthly customer-credit close types (SPEC BC-US-163…165, BC-TASK-104).
// They mirror the GraphQL schema artifact exactly.

// CreditClosePolicy is an accountant-approved posting-policy version.
type CreditClosePolicy struct {
	ID                         string `json:"id"`
	Version                    int    `json:"version"`
	EffectiveFrom              string `json:"effectiveFrom"`
	JournalNumber              int    `json:"journalNumber"`
	LiabilityAccountNumber     int    `json:"liabilityAccountNumber"`
	PostingMode                string `json:"postingMode"`
	DefaultOffsetAccountNumber *int   `json:"defaultOffsetAccountNumber"`
	PostZeroDelta              bool   `json:"postZeroDelta"`
	VatNeutral                 bool   `json:"vatNeutral"`
	SettlementMode             string `json:"settlementMode"`
	SettlementClearingAccount  *int   `json:"settlementClearingAccountNumber"`
	SettlementContraAccount    *int   `json:"settlementContraAccountNumber"`
}

// CreditCloseMovement is one movement-type roll-up row of a close.
type CreditCloseMovement struct {
	MovementType         string `json:"movementType"`
	AmountMinor          int64  `json:"amountMinor"`
	LiabilityEffectMinor int64  `json:"liabilityEffectMinor"`
	TransactionCount     int    `json:"transactionCount"`
}

// CreditCloseEvidence is metadata of one immutable evidence file.
type CreditCloseEvidence struct {
	EvidenceType string `json:"evidenceType"`
	Sha256       string `json:"sha256"`
	ContentType  string `json:"contentType"`
	ByteSize     int64  `json:"byteSize"`
}

// CreditClose is one monthly customer-credit close (§11.5 lifecycle).
type CreditClose struct {
	ID                         string                `json:"id"`
	State                      string                `json:"state"`
	CloseKind                  string                `json:"closeKind"`
	ReversalOfCloseID          *string               `json:"reversalOfCloseId"`
	Currency                   string                `json:"currency"`
	PeriodStart                string                `json:"periodStart"`
	PeriodEndExclusive         string                `json:"periodEndExclusive"`
	TransactionCutoff          string                `json:"transactionCutoff"`
	OpeningMinor               *int64                `json:"openingMinor"`
	ClosingMinor               *int64                `json:"closingMinor"`
	NetChangeMinor             *int64                `json:"netChangeMinor"`
	EconomicLiabilityLineMinor *int64                `json:"economicLiabilityLineMinor"`
	LedgerTransactionCount     *int                  `json:"ledgerTransactionCount"`
	ReportSha256               *string               `json:"reportSha256"`
	ClosedAt                   *string               `json:"closedAt"`
	ExternalVoucherNumber      *string               `json:"externalVoucherNumber"`
	Movements                  []CreditCloseMovement `json:"movements"`
	Evidence                   []CreditCloseEvidence `json:"evidence"`
}

// CreditCloseReport is one immutable evidence file with its exact bytes.
type CreditCloseReport struct {
	EvidenceType  string `json:"evidenceType"`
	Sha256        string `json:"sha256"`
	ContentType   string `json:"contentType"`
	ContentBase64 string `json:"contentBase64"`
}

// Bytes decodes the base64 payload into the exact stored evidence bytes.
func (r *CreditCloseReport) Bytes() ([]byte, error) {
	data, err := base64.StdEncoding.DecodeString(r.ContentBase64)
	if err != nil {
		return nil, fmt.Errorf("decode report content: %w", err)
	}
	return data, nil
}

const creditClosePolicyFields = `id version effectiveFrom journalNumber liabilityAccountNumber postingMode defaultOffsetAccountNumber postZeroDelta vatNeutral settlementMode settlementClearingAccountNumber settlementContraAccountNumber`

var creditCloseFields = `id state closeKind reversalOfCloseId currency periodStart periodEndExclusive transactionCutoff ` +
	`openingMinor closingMinor netChangeMinor economicLiabilityLineMinor ledgerTransactionCount ` +
	`reportSha256 closedAt externalVoucherNumber ` +
	`movements { movementType amountMinor liabilityEffectMinor transactionCount } ` +
	`evidence { evidenceType sha256 contentType byteSize }`

// CreditClose fetches one close by ID.
func (c *Client) CreditClose(ctx context.Context, correlationID, teamID, id string) (*CreditClose, error) {
	doc := `query RevrynCreditClose($teamId: ID!, $id: ID!) { creditClose(teamId: $teamId, id: $id) { ` + creditCloseFields + ` } }`
	var resp struct {
		CreditClose *CreditClose `json:"creditClose"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID, "id": id}, &resp); err != nil {
		return nil, err
	}
	if resp.CreditClose == nil {
		return nil, &NotFoundError{Resource: "credit close", ID: id}
	}
	return resp.CreditClose, nil
}

// CreditCloses lists the team's closes, newest period first (max 100).
func (c *Client) CreditCloses(ctx context.Context, correlationID, teamID, currency, state string) ([]CreditClose, error) {
	doc := `query RevrynCreditCloses($teamId: ID!, $currency: String, $state: String) {
  creditCloses(teamId: $teamId, currency: $currency, state: $state) { ` + creditCloseFields + ` }
}`
	vars := map[string]any{"teamId": teamID}
	if currency != "" {
		vars["currency"] = currency
	}
	if state != "" {
		vars["state"] = state
	}
	var resp struct {
		CreditCloses []CreditClose `json:"creditCloses"`
	}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	return resp.CreditCloses, nil
}

// CreditClosePolicies lists the team's posting-policy versions, newest first.
func (c *Client) CreditClosePolicies(ctx context.Context, correlationID, teamID string) ([]CreditClosePolicy, error) {
	doc := `query RevrynCreditClosePolicies($teamId: ID!) { creditClosePolicies(teamId: $teamId) { ` + creditClosePolicyFields + ` } }`
	var resp struct {
		CreditClosePolicies []CreditClosePolicy `json:"creditClosePolicies"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID}, &resp); err != nil {
		return nil, err
	}
	return resp.CreditClosePolicies, nil
}

// CreditCloseReport fetches one evidence file with its exact bytes.
func (c *Client) CreditCloseReport(ctx context.Context, correlationID, teamID, id, evidenceType string) (*CreditCloseReport, error) {
	doc := `query RevrynCreditCloseReport($teamId: ID!, $id: ID!, $evidenceType: String!) {
  creditClose(teamId: $teamId, id: $id) { report(evidenceType: $evidenceType) { evidenceType sha256 contentType contentBase64 } }
}`
	var resp struct {
		CreditClose *struct {
			Report *CreditCloseReport `json:"report"`
		} `json:"creditClose"`
	}
	vars := map[string]any{"teamId": teamID, "id": id, "evidenceType": evidenceType}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	if resp.CreditClose == nil || resp.CreditClose.Report == nil {
		return nil, &NotFoundError{Resource: "credit close report", ID: id + "/" + evidenceType}
	}
	return resp.CreditClose.Report, nil
}

// CreateCreditClosePolicyInput mirrors the GraphQL input type.
type CreateCreditClosePolicyInput struct {
	TeamID                     string `json:"teamId"`
	EffectiveFrom              string `json:"effectiveFrom"`
	JournalNumber              int    `json:"journalNumber"`
	LiabilityAccountNumber     int    `json:"liabilityAccountNumber"`
	DefaultOffsetAccountNumber int    `json:"defaultOffsetAccountNumber"`
	PostZeroDelta              bool   `json:"postZeroDelta"`
	SettlementMode             string `json:"settlementMode,omitempty"`
	SettlementClearingAccount  *int   `json:"settlementClearingAccountNumber,omitempty"`
	SettlementContraAccount    *int   `json:"settlementContraAccountNumber,omitempty"`
	ClientMutationID           string `json:"clientMutationId"`
}

// CreateCreditClosePolicy creates a monthly-close posting-policy version.
func (c *Client) CreateCreditClosePolicy(ctx context.Context, correlationID string, input CreateCreditClosePolicyInput) (*CreditClosePolicy, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynCreateCreditClosePolicy($input: CreateCreditClosePolicyInput!) {
  createCreditClosePolicy(input: $input) {
    __typename
    ... on CreateCreditClosePolicySuccess { policy { ` + creditClosePolicyFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "createCreditClosePolicy", input)
	if err != nil {
		return nil, err
	}
	return p.Policy, nil
}

// GenerateCreditCloseInput mirrors the GraphQL input type.
type GenerateCreditCloseInput struct {
	TeamID                string `json:"teamId"`
	Currency              string `json:"currency"`
	PeriodDate            string `json:"periodDate"`
	BootstrapOpeningMinor *int64 `json:"bootstrapOpeningMinor,omitempty"`
	PolicyVersionID       string `json:"policyVersionId,omitempty"`
	IdempotencyKey        string `json:"idempotencyKey"`
	ClientMutationID      string `json:"clientMutationId"`
}

// GenerateCreditClose freezes one deterministic close for a currency and
// calendar month (BC-US-163).
func (c *Client) GenerateCreditClose(ctx context.Context, correlationID string, input GenerateCreditCloseInput) (*CreditClose, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynGenerateCreditClose($input: GenerateCreditCloseInput!) {
  generateCreditClose(input: $input) {
    __typename
    ... on GenerateCreditCloseSuccess { creditClose { ` + creditCloseFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "generateCreditClose", input)
	if err != nil {
		return nil, err
	}
	return p.CreditClose, nil
}

// ApproveCreditCloseInput mirrors the GraphQL input type. The upstream
// contract defines no idempotency key for approval.
type ApproveCreditCloseInput struct {
	TeamID           string `json:"teamId"`
	CreditCloseID    string `json:"creditCloseId"`
	Reason           string `json:"reason,omitempty"`
	ClientMutationID string `json:"clientMutationId"`
}

// ApproveCreditClose approves the exact frozen report hash (BC-US-164).
func (c *Client) ApproveCreditClose(ctx context.Context, correlationID string, input ApproveCreditCloseInput) (*CreditClose, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynApproveCreditClose($input: ApproveCreditCloseInput!) {
  approveCreditClose(input: $input) {
    __typename
    ... on ApproveCreditCloseSuccess { creditClose { ` + creditCloseFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "approveCreditClose", input)
	if err != nil {
		return nil, err
	}
	return p.CreditClose, nil
}

// RequestCreditClosePostingInput mirrors the GraphQL input type.
type RequestCreditClosePostingInput struct {
	TeamID           string `json:"teamId"`
	CreditCloseID    string `json:"creditCloseId"`
	IdempotencyKey   string `json:"idempotencyKey"`
	ClientMutationID string `json:"clientMutationId"`
}

// CreditClosePosting is the durable posting operation with the close it acts on.
type CreditClosePosting struct {
	Operation   *Operation   `json:"operation"`
	CreditClose *CreditClose `json:"creditClose"`
}

// RequestCreditClosePosting creates the durable, idempotent ERP posting
// operation for an approved close (BC-US-164).
func (c *Client) RequestCreditClosePosting(ctx context.Context, correlationID string, input RequestCreditClosePostingInput) (*CreditClosePosting, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynRequestCreditClosePosting($input: RequestCreditClosePostingInput!) {
  requestCreditClosePosting(input: $input) {
    __typename
    ... on RequestCreditClosePostingSuccess {
      operation { ` + operationFields + ` }
      creditClose { ` + creditCloseFields + ` }
    }
    ` + fragValidation + `
    ` + fragAuthorization + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "requestCreditClosePosting", input)
	if err != nil {
		return nil, err
	}
	return &CreditClosePosting{Operation: p.Operation, CreditClose: p.CreditClose}, nil
}

// RequestCreditCloseReversalInput mirrors the GraphQL input type.
type RequestCreditCloseReversalInput struct {
	TeamID           string `json:"teamId"`
	CreditCloseID    string `json:"creditCloseId"`
	Reason           string `json:"reason"`
	ClientMutationID string `json:"clientMutationId"`
}

// RequestCreditCloseReversal freezes a compensating reversal close for an
// accepted close (ADR-031, BC-US-165).
func (c *Client) RequestCreditCloseReversal(ctx context.Context, correlationID string, input RequestCreditCloseReversalInput) (*CreditClose, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynRequestCreditCloseReversal($input: RequestCreditCloseReversalInput!) {
  requestCreditCloseReversal(input: $input) {
    __typename
    ... on RequestCreditCloseReversalSuccess { reversalClose { ` + creditCloseFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "requestCreditCloseReversal", input)
	if err != nil {
		return nil, err
	}
	return p.ReversalClose, nil
}

// GenerateCreditCloseReplacementInput mirrors the GraphQL input type.
type GenerateCreditCloseReplacementInput struct {
	TeamID           string `json:"teamId"`
	CreditCloseID    string `json:"creditCloseId"`
	PolicyVersionID  string `json:"policyVersionId"`
	Reason           string `json:"reason"`
	ClientMutationID string `json:"clientMutationId"`
}

// GenerateCreditCloseReplacement freezes a replacement close for a reversed
// period under a corrected policy version (ADR-031).
func (c *Client) GenerateCreditCloseReplacement(ctx context.Context, correlationID string, input GenerateCreditCloseReplacementInput) (*CreditClose, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynGenerateCreditCloseReplacement($input: GenerateCreditCloseReplacementInput!) {
  generateCreditCloseReplacement(input: $input) {
    __typename
    ... on GenerateCreditCloseReplacementSuccess { replacementClose { ` + creditCloseFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "generateCreditCloseReplacement", input)
	if err != nil {
		return nil, err
	}
	return p.ReplacementClose, nil
}

// CloseCreditPeriodInput mirrors the GraphQL input type.
type CloseCreditPeriodInput struct {
	TeamID           string `json:"teamId"`
	CreditCloseID    string `json:"creditCloseId"`
	ClientMutationID string `json:"clientMutationId"`
}

// CloseCreditPeriod accepts a fully reconciled close as the authoritative
// period close (BC-US-165).
func (c *Client) CloseCreditPeriod(ctx context.Context, correlationID string, input CloseCreditPeriodInput) (*CreditClose, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynCloseCreditPeriod($input: CloseCreditPeriodInput!) {
  closeCreditPeriod(input: $input) {
    __typename
    ... on CloseCreditPeriodSuccess { creditClose { ` + creditCloseFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "closeCreditPeriod", input)
	if err != nil {
		return nil, err
	}
	return p.CreditClose, nil
}
