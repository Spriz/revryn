package client

import "context"

// Customer-credit subledger types (SPEC BC-US-107…109, §9.4.1). They
// mirror the GraphQL schema artifact exactly.

// CreditGrant is an individual liability movement, never a discount.
type CreditGrant struct {
	ID             string  `json:"id"`
	OriginType     string  `json:"originType"`
	OriginID       *string `json:"originId"`
	GrantedMinor   int64   `json:"grantedMinor"`
	RemainingMinor int64   `json:"remainingMinor"`
	ReservedMinor  int64   `json:"reservedMinor"`
	Currency       string  `json:"currency"`
	Status         string  `json:"status"`
	GrantedAt      string  `json:"grantedAt"`
	ExpiresAt      *string `json:"expiresAt"`
}

// CreditTransaction is one append-only subledger transaction.
type CreditTransaction struct {
	ID                    string  `json:"id"`
	TransactionType       string  `json:"transactionType"`
	AmountMinor           int64   `json:"amountMinor"`
	Currency              string  `json:"currency"`
	GrantID               *string `json:"grantId"`
	InvoiceIntentID       *string `json:"invoiceIntentId"`
	ReasonCode            *string `json:"reasonCode"`
	AccountingEffectiveOn string  `json:"accountingEffectiveOn"`
	OccurredAt            string  `json:"occurredAt"`
}

// CreditDispositionPolicy is a versioned remaining-credit policy (BC-US-109).
type CreditDispositionPolicy struct {
	Version         int    `json:"version"`
	Policy          string `json:"policy"`
	ExpireAfterDays *int   `json:"expireAfterDays"`
	EffectiveFrom   string `json:"effectiveFrom"`
}

// CreditAccount is a team-scoped projection over the append-only ledger.
type CreditAccount struct {
	ID                string                   `json:"id"`
	AccountID         string                   `json:"accountId"`
	Currency          string                   `json:"currency"`
	AvailableMinor    int64                    `json:"availableMinor"`
	ReservedMinor     int64                    `json:"reservedMinor"`
	Grants            []CreditGrant            `json:"grants"`
	Transactions      []CreditTransaction      `json:"transactions"`
	DispositionPolicy *CreditDispositionPolicy `json:"dispositionPolicy"`
}

// CreditSettlement is one receivable settlement opened by one credit
// application (SPEC §9.4.1).
type CreditSettlement struct {
	ID                    string  `json:"id"`
	InvoiceIntentID       string  `json:"invoiceIntentId"`
	CreditAccountID       string  `json:"creditAccountId"`
	Currency              string  `json:"currency"`
	AmountMinor           int64   `json:"amountMinor"`
	Mode                  string  `json:"mode"`
	State                 string  `json:"state"`
	ExternalReference     *string `json:"externalReference"`
	ExternalVoucherNumber *string `json:"externalVoucherNumber"`
	ReconciledAt          *string `json:"reconciledAt"`
	CreatedAt             string  `json:"createdAt"`
}

const creditDispositionPolicyFields = `version policy expireAfterDays effectiveFrom`

var creditAccountFields = `id accountId currency availableMinor reservedMinor ` +
	`grants { id originType originId grantedMinor remainingMinor reservedMinor currency status grantedAt expiresAt } ` +
	`transactions { id transactionType amountMinor currency grantId invoiceIntentId reasonCode accountingEffectiveOn occurredAt } ` +
	`dispositionPolicy { ` + creditDispositionPolicyFields + ` }`

const creditSettlementFields = `id invoiceIntentId creditAccountId currency amountMinor mode state ` +
	`externalReference externalVoucherNumber reconciledAt createdAt`

// CreditAccounts lists a customer's credit accounts with subledger evidence.
func (c *Client) CreditAccounts(ctx context.Context, correlationID, teamID, customerID string) ([]CreditAccount, error) {
	doc := `query RevrynCreditAccounts($teamId: ID!, $customerId: ID!) {
  creditAccounts(teamId: $teamId, customerId: $customerId) { ` + creditAccountFields + ` }
}`
	var resp struct {
		CreditAccounts []CreditAccount `json:"creditAccounts"`
	}
	vars := map[string]any{"teamId": teamID, "customerId": customerID}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	return resp.CreditAccounts, nil
}

// CreditSettlements lists receivable settlements, newest first.
func (c *Client) CreditSettlements(ctx context.Context, correlationID, teamID, invoiceIntentID, state string) ([]CreditSettlement, error) {
	doc := `query RevrynCreditSettlements($teamId: ID!, $invoiceIntentId: ID, $state: String) {
  creditSettlements(teamId: $teamId, invoiceIntentId: $invoiceIntentId, state: $state) { ` + creditSettlementFields + ` }
}`
	vars := map[string]any{"teamId": teamID}
	if invoiceIntentID != "" {
		vars["invoiceIntentId"] = invoiceIntentID
	}
	if state != "" {
		vars["state"] = state
	}
	var resp struct {
		CreditSettlements []CreditSettlement `json:"creditSettlements"`
	}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	return resp.CreditSettlements, nil
}

// GrantCreditInput mirrors the GraphQL input type.
type GrantCreditInput struct {
	TeamID           string  `json:"teamId"`
	CreditAccountID  string  `json:"creditAccountId"`
	OriginType       string  `json:"originType"`
	AmountMinor      int64   `json:"amountMinor"`
	Currency         string  `json:"currency"`
	ReasonCode       string  `json:"reasonCode,omitempty"`
	ExpiresAt        *string `json:"expiresAt,omitempty"`
	IdempotencyKey   string  `json:"idempotencyKey"`
	ClientMutationID string  `json:"clientMutationId"`
}

// GrantCredit grants customer credit into the subledger — a liability,
// never a discount (BC-US-107).
func (c *Client) GrantCredit(ctx context.Context, correlationID string, input GrantCreditInput) (*CreditGrant, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynGrantCredit($input: GrantCreditInput!) {
  grantCredit(input: $input) {
    __typename
    ... on GrantCreditSuccess { creditGrant { id originType originId grantedMinor remainingMinor reservedMinor currency status grantedAt expiresAt } }
    ` + fragValidation + `
    ` + fragAuthorization + `
    ... on IdempotencyConflict { code message }
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "grantCredit", input)
	if err != nil {
		return nil, err
	}
	return p.CreditGrant, nil
}

// SetCreditDispositionPolicyInput mirrors the GraphQL input type.
type SetCreditDispositionPolicyInput struct {
	TeamID           string `json:"teamId"`
	CreditAccountID  string `json:"creditAccountId"`
	Policy           string `json:"policy"`
	ExpireAfterDays  *int   `json:"expireAfterDays,omitempty"`
	ClientMutationID string `json:"clientMutationId"`
}

// SetCreditDispositionPolicy sets the versioned remaining-credit
// disposition policy (BC-US-109).
func (c *Client) SetCreditDispositionPolicy(ctx context.Context, correlationID string, input SetCreditDispositionPolicyInput) (*CreditDispositionPolicy, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynSetCreditDispositionPolicy($input: SetCreditDispositionPolicyInput!) {
  setCreditDispositionPolicy(input: $input) {
    __typename
    ... on SetCreditDispositionPolicySuccess { dispositionPolicy { ` + creditDispositionPolicyFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "setCreditDispositionPolicy", input)
	if err != nil {
		return nil, err
	}
	return p.DispositionPolicy, nil
}

// RecordExternalSettlementInput mirrors the GraphQL input type.
type RecordExternalSettlementInput struct {
	TeamID            string `json:"teamId"`
	SettlementID      string `json:"settlementId"`
	ExternalReference string `json:"externalReference"`
	ClientMutationID  string `json:"clientMutationId"`
}

// RecordExternalSettlement records the authoritative external receivables
// system's settlement reference exactly once (SPEC §9.4.1).
func (c *Client) RecordExternalSettlement(ctx context.Context, correlationID string, input RecordExternalSettlementInput) (*CreditSettlement, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynRecordExternalSettlement($input: RecordExternalSettlementInput!) {
  recordExternalSettlement(input: $input) {
    __typename
    ... on RecordExternalSettlementSuccess { settlement { ` + creditSettlementFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "recordExternalSettlement", input)
	if err != nil {
		return nil, err
	}
	return p.Settlement, nil
}
