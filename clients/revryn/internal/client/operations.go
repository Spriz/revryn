package client

import (
	"context"
	"fmt"
)

// Field selections shared across documents. These mirror the schema artifact
// exactly; they are implementation detail (SPEC §14.14).
const (
	customerFields     = `id externalId status currentVersion legalName`
	subscriptionFields = `id externalId contractId state startsOn endDateExclusive billingAnchorDay timeZone version currentVersion`
	invoiceLineFields  = `id lineKey description quantity amountMinor currency recognitionMode serviceStart serviceEndExclusive ordinal productId productVersion`
	previewLineFields  = `lineKey description quantity amountMinor recognitionMode serviceStart serviceEndExclusive ordinal productId`
	operationFields    = `id type state attemptCount errorClass safeErrorCode safeErrorSummary blockedReason nextAttemptAt correlationId startedAt finishedAt`
	billingRunFields   = `id runKey status invoiceDate usageCutoff engineVersion startedAt closedAt`
)

var (
	invoiceIntentFields  = `id state customerId customerVersion contractId billingRunId currency invoiceDate intentVersion supersedesInvoiceIntentId documentKind contentHash netAmountMinor frozenAt lines { ` + invoiceLineFields + ` }`
	invoicePreviewFields = `subscriptionId customerId contractId currency invoiceDate periodStart periodEndExclusive netAmountMinor fingerprint blockers lines { ` + previewLineFields + ` }`
)

// Problem fragments; composed per mutation to match each union exactly.
const (
	fragValidation      = `... on ValidationProblem { code message fields { path code message } }`
	fragMapping         = `... on MappingProblem { code message fields { path code message } }`
	fragAuthorization   = `... on AuthorizationProblem { code message }`
	fragVersionConflict = `... on VersionConflict { expectedVersion actualVersion }`
	fragIdempotency     = `... on IdempotencyConflict { code message }`
)

// mutationPayload decodes any mutation union member; exactly one success
// carrier is set on success, and problem carriers otherwise.
type mutationPayload struct {
	Typename string `json:"__typename"`

	Subscription      *Subscription            `json:"subscription"`
	InvoiceIntent     *InvoiceIntent           `json:"invoiceIntent"`
	Operation         *Operation               `json:"operation"`
	BillingRun        *BillingRun              `json:"billingRun"`
	CreditClose       *CreditClose             `json:"creditClose"`
	ReversalClose     *CreditClose             `json:"reversalClose"`
	ReplacementClose  *CreditClose             `json:"replacementClose"`
	Policy            *CreditClosePolicy       `json:"policy"`
	CreditGrant       *CreditGrant             `json:"creditGrant"`
	DispositionPolicy *CreditDispositionPolicy `json:"dispositionPolicy"`
	Settlement        *CreditSettlement        `json:"settlement"`

	Code            string         `json:"code"`
	Message         string         `json:"message"`
	Fields          []FieldProblem `json:"fields"`
	ExpectedVersion *int           `json:"expectedVersion"`
	ActualVersion   *int           `json:"actualVersion"`
}

// problem maps a problem typename to a *ProblemError, or nil for success.
func (p *mutationPayload) problem() *ProblemError {
	var kind ProblemKind
	switch p.Typename {
	case "ValidationProblem":
		kind = ProblemValidation
	case "MappingProblem":
		kind = ProblemMapping
	case "AuthorizationProblem":
		kind = ProblemAuthorization
	case "VersionConflict":
		kind = ProblemVersionConflict
	case "IdempotencyConflict":
		kind = ProblemIdempotencyConflict
	default:
		return nil
	}
	return &ProblemError{
		Typename:        p.Typename,
		Kind:            kind,
		Code:            p.Code,
		Message:         p.Message,
		Fields:          p.Fields,
		ExpectedVersion: p.ExpectedVersion,
		ActualVersion:   p.ActualVersion,
	}
}

// mutate executes a mutation document with a single $input variable and
// returns the decoded payload of the given top-level field, mapping typed
// problem results to *ProblemError.
func (c *Client) mutate(ctx context.Context, correlationID, doc, field string, input any) (*mutationPayload, error) {
	var resp map[string]*mutationPayload
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"input": input}, &resp); err != nil {
		return nil, err
	}
	p := resp[field]
	if p == nil {
		return nil, fmt.Errorf("response missing %q payload", field)
	}
	if pe := p.problem(); pe != nil {
		return nil, pe
	}
	return p, nil
}

// --- Queries ---

// APIVersion fetches the schema/contract version marker.
func (c *Client) APIVersion(ctx context.Context, correlationID string) (string, error) {
	var resp struct {
		APIVersion string `json:"apiVersion"`
	}
	if err := c.Execute(ctx, correlationID, `query RevrynAPIVersion { apiVersion }`, nil, &resp); err != nil {
		return "", err
	}
	return resp.APIVersion, nil
}

// Status fetches apiVersion plus the viewer and its memberships.
func (c *Client) Status(ctx context.Context, correlationID string) (*StatusResult, error) {
	doc := `query RevrynStatus {
  apiVersion
  viewer {
    id status platformAdmin
    organizationMemberships { organization { id name slug status } roles }
    teamMemberships { team { id organizationId name slug legalName baseCurrency timeZone locale status } roles }
  }
}`
	var resp StatusResult
	if err := c.Execute(ctx, correlationID, doc, nil, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

// Customer fetches a team customer by ID.
func (c *Client) Customer(ctx context.Context, correlationID, teamID, id string) (*Customer, error) {
	doc := `query RevrynCustomer($teamId: ID!, $id: ID!) { customer(teamId: $teamId, id: $id) { ` + customerFields + ` } }`
	var resp struct {
		Customer *Customer `json:"customer"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID, "id": id}, &resp); err != nil {
		return nil, err
	}
	if resp.Customer == nil {
		return nil, &NotFoundError{Resource: "customer", ID: id}
	}
	return resp.Customer, nil
}

// Customers lists team customers as a bounded cursor connection.
func (c *Client) Customers(ctx context.Context, correlationID, teamID string, first int, after string) (*CustomerConnection, error) {
	doc := `query RevrynCustomers($teamId: ID!, $first: Int, $after: String) {
  customers(teamId: $teamId, first: $first, after: $after) {
    edges { cursor node { ` + customerFields + ` } }
    pageInfo { hasNextPage endCursor }
  }
}`
	vars := map[string]any{"teamId": teamID}
	if first > 0 {
		vars["first"] = first
	}
	if after != "" {
		vars["after"] = after
	}
	var resp struct {
		Customers *CustomerConnection `json:"customers"`
	}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	if resp.Customers == nil {
		return nil, &NotFoundError{Resource: "customers for team", ID: teamID}
	}
	return resp.Customers, nil
}

// Subscription fetches a subscription by ID.
func (c *Client) Subscription(ctx context.Context, correlationID, teamID, id string) (*Subscription, error) {
	doc := `query RevrynSubscription($teamId: ID!, $id: ID!) { subscription(teamId: $teamId, id: $id) { ` + subscriptionFields + ` } }`
	var resp struct {
		Subscription *Subscription `json:"subscription"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID, "id": id}, &resp); err != nil {
		return nil, err
	}
	if resp.Subscription == nil {
		return nil, &NotFoundError{Resource: "subscription", ID: id}
	}
	return resp.Subscription, nil
}

// Subscriptions lists team subscriptions as a bounded cursor connection.
func (c *Client) Subscriptions(ctx context.Context, correlationID, teamID string, first int, after string) (*SubscriptionConnection, error) {
	doc := `query RevrynSubscriptions($teamId: ID!, $first: Int, $after: String) {
  subscriptions(teamId: $teamId, first: $first, after: $after) {
    edges { cursor node { ` + subscriptionFields + ` } }
    pageInfo { hasNextPage endCursor }
  }
}`
	vars := map[string]any{"teamId": teamID}
	if first > 0 {
		vars["first"] = first
	}
	if after != "" {
		vars["after"] = after
	}
	var resp struct {
		Subscriptions *SubscriptionConnection `json:"subscriptions"`
	}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	if resp.Subscriptions == nil {
		return nil, &NotFoundError{Resource: "subscriptions for team", ID: teamID}
	}
	return resp.Subscriptions, nil
}

// InvoicePreview fetches the deterministic invoice preview (BC-US-068).
func (c *Client) InvoicePreview(ctx context.Context, correlationID, teamID, subscriptionID, asOf string) (*InvoicePreview, error) {
	doc := `query RevrynInvoicePreview($teamId: ID!, $subscriptionId: ID!, $asOf: Date!) {
  invoicePreview(teamId: $teamId, subscriptionId: $subscriptionId, asOf: $asOf) { ` + invoicePreviewFields + ` }
}`
	var resp struct {
		InvoicePreview *InvoicePreview `json:"invoicePreview"`
	}
	vars := map[string]any{"teamId": teamID, "subscriptionId": subscriptionID, "asOf": asOf}
	if err := c.Execute(ctx, correlationID, doc, vars, &resp); err != nil {
		return nil, err
	}
	if resp.InvoicePreview == nil {
		return nil, &NotFoundError{Resource: "invoice preview for subscription", ID: subscriptionID}
	}
	return resp.InvoicePreview, nil
}

// InvoiceIntent fetches an invoice intent including state and lines.
func (c *Client) InvoiceIntent(ctx context.Context, correlationID, teamID, id string) (*InvoiceIntent, error) {
	doc := `query RevrynInvoiceIntent($teamId: ID!, $id: ID!) { invoiceIntent(teamId: $teamId, id: $id) { ` + invoiceIntentFields + ` } }`
	var resp struct {
		InvoiceIntent *InvoiceIntent `json:"invoiceIntent"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID, "id": id}, &resp); err != nil {
		return nil, err
	}
	if resp.InvoiceIntent == nil {
		return nil, &NotFoundError{Resource: "invoice intent", ID: id}
	}
	return resp.InvoiceIntent, nil
}

// Operation fetches a durable operation by ID.
func (c *Client) Operation(ctx context.Context, correlationID, teamID, id string) (*Operation, error) {
	doc := `query RevrynOperation($teamId: ID!, $id: ID!) { operation(teamId: $teamId, id: $id) { ` + operationFields + ` } }`
	var resp struct {
		Operation *Operation `json:"operation"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID, "id": id}, &resp); err != nil {
		return nil, err
	}
	if resp.Operation == nil {
		return nil, &NotFoundError{Resource: "operation", ID: id}
	}
	return resp.Operation, nil
}

// BillingRun fetches a billing run by ID.
func (c *Client) BillingRun(ctx context.Context, correlationID, teamID, id string) (*BillingRun, error) {
	doc := `query RevrynBillingRun($teamId: ID!, $id: ID!) { billingRun(teamId: $teamId, id: $id) { ` + billingRunFields + ` } }`
	var resp struct {
		BillingRun *BillingRun `json:"billingRun"`
	}
	if err := c.Execute(ctx, correlationID, doc, map[string]any{"teamId": teamID, "id": id}, &resp); err != nil {
		return nil, err
	}
	if resp.BillingRun == nil {
		return nil, &NotFoundError{Resource: "billing run", ID: id}
	}
	return resp.BillingRun, nil
}

// --- Mutations ---

// CreateSubscriptionInput mirrors the GraphQL input type. IdempotencyKey and
// ClientMutationID are auto-filled when empty.
type CreateSubscriptionInput struct {
	TeamID           string `json:"teamId"`
	ContractID       string `json:"contractId"`
	ExternalID       string `json:"externalId"`
	PlanVersionID    string `json:"planVersionId"`
	StartsOn         string `json:"startsOn"`
	EndDateExclusive string `json:"endDateExclusive,omitempty"`
	BillingAnchorDay int    `json:"billingAnchorDay,omitempty"`
	Quantity         string `json:"quantity"`
	IdempotencyKey   string `json:"idempotencyKey"`
	ClientMutationID string `json:"clientMutationId"`
}

// CreateSubscription starts a subscription (BC-US-034/035, SPEC §14.9).
func (c *Client) CreateSubscription(ctx context.Context, correlationID string, input CreateSubscriptionInput) (*Subscription, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynCreateSubscription($input: CreateSubscriptionInput!) {
  createSubscription(input: $input) {
    __typename
    ... on CreateSubscriptionSuccess { subscription { ` + subscriptionFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
    ` + fragVersionConflict + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "createSubscription", input)
	if err != nil {
		return nil, err
	}
	return p.Subscription, nil
}

// FreezeInvoiceIntentInput mirrors the GraphQL input type.
type FreezeInvoiceIntentInput struct {
	TeamID           string `json:"teamId"`
	SubscriptionID   string `json:"subscriptionId"`
	AsOf             string `json:"asOf"`
	BillingRunID     string `json:"billingRunId,omitempty"`
	IdempotencyKey   string `json:"idempotencyKey"`
	ClientMutationID string `json:"clientMutationId"`
}

// FreezeInvoiceIntent freezes a subscription's preview into an immutable
// invoice intent (BC-US-069).
func (c *Client) FreezeInvoiceIntent(ctx context.Context, correlationID string, input FreezeInvoiceIntentInput) (*InvoiceIntent, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynFreezeInvoiceIntent($input: FreezeInvoiceIntentInput!) {
  freezeInvoiceIntent(input: $input) {
    __typename
    ... on FreezeInvoiceIntentSuccess { invoiceIntent { ` + invoiceIntentFields + ` } }
    ` + fragValidation + `
    ` + fragMapping + `
    ` + fragAuthorization + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "freezeInvoiceIntent", input)
	if err != nil {
		return nil, err
	}
	return p.InvoiceIntent, nil
}

// SynchronizeInvoiceInput mirrors the GraphQL input type.
type SynchronizeInvoiceInput struct {
	TeamID           string `json:"teamId"`
	InvoiceIntentID  string `json:"invoiceIntentId"`
	IdempotencyKey   string `json:"idempotencyKey"`
	ClientMutationID string `json:"clientMutationId"`
}

// SynchronizeInvoice enqueues ERP draft synchronization and returns the
// durable operation to follow (SPEC §14.11).
func (c *Client) SynchronizeInvoice(ctx context.Context, correlationID string, input SynchronizeInvoiceInput) (*Operation, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynSynchronizeInvoice($input: SynchronizeInvoiceInput!) {
  synchronizeInvoice(input: $input) {
    __typename
    ... on SynchronizeInvoiceAccepted { operation { ` + operationFields + ` } }
    ` + fragMapping + `
    ` + fragValidation + `
    ` + fragAuthorization + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "synchronizeInvoice", input)
	if err != nil {
		return nil, err
	}
	return p.Operation, nil
}

// ApproveInvoiceInput mirrors the GraphQL input type. The upstream contract
// defines no idempotency key for approval.
type ApproveInvoiceInput struct {
	TeamID           string `json:"teamId"`
	InvoiceIntentID  string `json:"invoiceIntentId"`
	Reason           string `json:"reason,omitempty"`
	ClientMutationID string `json:"clientMutationId"`
}

// ApproveInvoice approves a reconciled ERP draft for booking (BC-US-084).
func (c *Client) ApproveInvoice(ctx context.Context, correlationID string, input ApproveInvoiceInput) (*InvoiceIntent, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynApproveInvoice($input: ApproveInvoiceInput!) {
  approveInvoice(input: $input) {
    __typename
    ... on ApproveInvoiceSuccess { invoiceIntent { ` + invoiceIntentFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "approveInvoice", input)
	if err != nil {
		return nil, err
	}
	return p.InvoiceIntent, nil
}

// BookInvoiceInput mirrors the GraphQL input type.
type BookInvoiceInput struct {
	TeamID           string `json:"teamId"`
	InvoiceIntentID  string `json:"invoiceIntentId"`
	IdempotencyKey   string `json:"idempotencyKey"`
	ClientMutationID string `json:"clientMutationId"`
}

// BookInvoice enqueues booking of an approved draft and returns the durable
// booking operation (BC-US-085).
func (c *Client) BookInvoice(ctx context.Context, correlationID string, input BookInvoiceInput) (*Operation, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynBookInvoice($input: BookInvoiceInput!) {
  bookInvoice(input: $input) {
    __typename
    ... on BookInvoiceAccepted { operation { ` + operationFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "bookInvoice", input)
	if err != nil {
		return nil, err
	}
	return p.Operation, nil
}

// RetryOperationInput mirrors the GraphQL input type. The upstream contract
// defines no idempotency key for manual retry.
type RetryOperationInput struct {
	TeamID           string `json:"teamId"`
	OperationID      string `json:"operationId"`
	ClientMutationID string `json:"clientMutationId"`
}

// RetryOperation manually retries a failed durable operation (SPEC §11.3).
func (c *Client) RetryOperation(ctx context.Context, correlationID string, input RetryOperationInput) (*Operation, error) {
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynRetryOperation($input: RetryOperationInput!) {
  retryOperation(input: $input) {
    __typename
    ... on RetryOperationSuccess { operation { ` + operationFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "retryOperation", input)
	if err != nil {
		return nil, err
	}
	return p.Operation, nil
}

// CreateBillingRunInput mirrors the GraphQL input type.
type CreateBillingRunInput struct {
	TeamID           string `json:"teamId"`
	RunKey           string `json:"runKey"`
	InvoiceDate      string `json:"invoiceDate"`
	UsageCutoff      string `json:"usageCutoff"`
	IdempotencyKey   string `json:"idempotencyKey"`
	ClientMutationID string `json:"clientMutationId"`
}

// CreateBillingRun opens (or returns) a billing run by stable run key
// (SPEC §18.1).
func (c *Client) CreateBillingRun(ctx context.Context, correlationID string, input CreateBillingRunInput) (*BillingRun, error) {
	if input.IdempotencyKey == "" {
		input.IdempotencyKey = NewIdempotencyKey()
	}
	if input.ClientMutationID == "" {
		input.ClientMutationID = correlationID
	}
	doc := `mutation RevrynCreateBillingRun($input: CreateBillingRunInput!) {
  createBillingRun(input: $input) {
    __typename
    ... on CreateBillingRunSuccess { billingRun { ` + billingRunFields + ` } }
    ` + fragValidation + `
    ` + fragAuthorization + `
    ` + fragIdempotency + `
  }
}`
	p, err := c.mutate(ctx, correlationID, doc, "createBillingRun", input)
	if err != nil {
		return nil, err
	}
	return p.BillingRun, nil
}
