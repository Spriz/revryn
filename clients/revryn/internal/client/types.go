package client

// DTOs mirroring schema/billing_core.graphql. Field names and nullability
// follow the schema artifact; nullable fields carry omitempty so both CLI
// JSON envelopes and MCP structured outputs stay minimal and stable.
//
// Scalars: Date/DateTime are ISO 8601 strings, Decimal is a string, and
// MoneyMinorUnits is an int64 (minor units, e.g. øre/cents).

// Viewer is the authenticated principal and its memberships.
type Viewer struct {
	ID                      string                         `json:"id"`
	Status                  string                         `json:"status"`
	PlatformAdmin           bool                           `json:"platformAdmin"`
	OrganizationMemberships []ViewerOrganizationMembership `json:"organizationMemberships,omitempty"`
	TeamMemberships         []ViewerTeamMembership         `json:"teamMemberships,omitempty"`
}

type ViewerOrganizationMembership struct {
	Organization Organization `json:"organization"`
	Roles        []string     `json:"roles,omitempty"`
}

type ViewerTeamMembership struct {
	Team  Team     `json:"team"`
	Roles []string `json:"roles,omitempty"`
}

type Organization struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Slug   string `json:"slug"`
	Status string `json:"status"`
}

type Team struct {
	ID             string `json:"id"`
	OrganizationID string `json:"organizationId"`
	Name           string `json:"name"`
	Slug           string `json:"slug"`
	LegalName      string `json:"legalName,omitempty"`
	BaseCurrency   string `json:"baseCurrency"`
	TimeZone       string `json:"timeZone"`
	Locale         string `json:"locale"`
	Status         string `json:"status"`
}

type Customer struct {
	ID             string `json:"id"`
	ExternalID     string `json:"externalId"`
	Status         string `json:"status"`
	CurrentVersion int    `json:"currentVersion"`
	LegalName      string `json:"legalName,omitempty"`
}

type PageInfo struct {
	HasNextPage bool   `json:"hasNextPage"`
	EndCursor   string `json:"endCursor,omitempty"`
}

type CustomerEdge struct {
	Cursor string   `json:"cursor"`
	Node   Customer `json:"node"`
}

type CustomerConnection struct {
	Edges    []CustomerEdge `json:"edges"`
	PageInfo PageInfo       `json:"pageInfo"`
}

// Subscription is a contract subscription (SPEC §11.1 lifecycle).
type Subscription struct {
	ID               string `json:"id"`
	ExternalID       string `json:"externalId"`
	ContractID       string `json:"contractId"`
	State            string `json:"state"`
	StartsOn         string `json:"startsOn"`
	EndDateExclusive string `json:"endDateExclusive,omitempty"`
	BillingAnchorDay int    `json:"billingAnchorDay,omitempty"`
	TimeZone         string `json:"timeZone"`
	Version          int    `json:"version"`
	CurrentVersion   int    `json:"currentVersion"`
}

type SubscriptionEdge struct {
	Cursor string       `json:"cursor"`
	Node   Subscription `json:"node"`
}

type SubscriptionConnection struct {
	Edges    []SubscriptionEdge `json:"edges"`
	PageInfo PageInfo           `json:"pageInfo"`
}

type InvoiceLine struct {
	ID                  string `json:"id"`
	LineKey             string `json:"lineKey"`
	Description         string `json:"description"`
	Quantity            string `json:"quantity"`
	AmountMinor         int64  `json:"amountMinor"`
	Currency            string `json:"currency"`
	RecognitionMode     string `json:"recognitionMode"`
	ServiceStart        string `json:"serviceStart,omitempty"`
	ServiceEndExclusive string `json:"serviceEndExclusive,omitempty"`
	Ordinal             int    `json:"ordinal"`
	ProductID           string `json:"productId"`
	ProductVersion      int    `json:"productVersion"`
}

// InvoiceIntent is an immutable frozen invoice intent plus its mutable
// lifecycle state (SPEC §11.2).
type InvoiceIntent struct {
	ID                        string        `json:"id"`
	State                     string        `json:"state"`
	CustomerID                string        `json:"customerId"`
	CustomerVersion           int           `json:"customerVersion"`
	ContractID                string        `json:"contractId,omitempty"`
	BillingRunID              string        `json:"billingRunId,omitempty"`
	Currency                  string        `json:"currency"`
	InvoiceDate               string        `json:"invoiceDate"`
	IntentVersion             int           `json:"intentVersion"`
	SupersedesInvoiceIntentID string        `json:"supersedesInvoiceIntentId,omitempty"`
	DocumentKind              string        `json:"documentKind"`
	ContentHash               string        `json:"contentHash"`
	NetAmountMinor            int64         `json:"netAmountMinor"`
	FrozenAt                  string        `json:"frozenAt,omitempty"`
	Lines                     []InvoiceLine `json:"lines"`
}

type PreviewLine struct {
	LineKey             string `json:"lineKey"`
	Description         string `json:"description"`
	Quantity            string `json:"quantity"`
	AmountMinor         int64  `json:"amountMinor"`
	RecognitionMode     string `json:"recognitionMode"`
	ServiceStart        string `json:"serviceStart,omitempty"`
	ServiceEndExclusive string `json:"serviceEndExclusive,omitempty"`
	Ordinal             int    `json:"ordinal"`
	ProductID           string `json:"productId"`
}

// InvoicePreview is a deterministic, side-effect-free preview (BC-US-068).
type InvoicePreview struct {
	SubscriptionID     string        `json:"subscriptionId"`
	CustomerID         string        `json:"customerId"`
	ContractID         string        `json:"contractId"`
	Currency           string        `json:"currency"`
	InvoiceDate        string        `json:"invoiceDate"`
	PeriodStart        string        `json:"periodStart"`
	PeriodEndExclusive string        `json:"periodEndExclusive"`
	NetAmountMinor     int64         `json:"netAmountMinor"`
	Fingerprint        string        `json:"fingerprint"`
	Blockers           []string      `json:"blockers"`
	Lines              []PreviewLine `json:"lines"`
}

// Operation is a durable asynchronous operation; clients follow it instead
// of HTTP 202 semantics (SPEC §14.11).
type Operation struct {
	ID               string `json:"id"`
	Type             string `json:"type"`
	State            string `json:"state"`
	AttemptCount     int    `json:"attemptCount"`
	ErrorClass       string `json:"errorClass,omitempty"`
	SafeErrorCode    string `json:"safeErrorCode,omitempty"`
	SafeErrorSummary string `json:"safeErrorSummary,omitempty"`
	BlockedReason    string `json:"blockedReason,omitempty"`
	NextAttemptAt    string `json:"nextAttemptAt,omitempty"`
	CorrelationID    string `json:"correlationId,omitempty"`
	StartedAt        string `json:"startedAt,omitempty"`
	FinishedAt       string `json:"finishedAt,omitempty"`
}

type BillingRun struct {
	ID            string `json:"id"`
	RunKey        string `json:"runKey"`
	Status        string `json:"status"`
	InvoiceDate   string `json:"invoiceDate"`
	UsageCutoff   string `json:"usageCutoff"`
	EngineVersion string `json:"engineVersion"`
	StartedAt     string `json:"startedAt,omitempty"`
	ClosedAt      string `json:"closedAt,omitempty"`
}

// StatusResult is the payload of `revryn status`.
type StatusResult struct {
	APIVersion string  `json:"apiVersion"`
	Viewer     *Viewer `json:"viewer,omitempty"`
}
