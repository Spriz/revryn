package mcpserver

import (
	"context"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/revryn/billing-core/internal/client"
)

// readOnly annotates a tool that performs no writes anywhere.
func readOnly(title string) *sdk.ToolAnnotations {
	return &sdk.ToolAnnotations{
		Title:        title,
		ReadOnlyHint: true,
	}
}

type teamScopedInput struct {
	TeamID string `json:"team_id,omitempty" jsonschema:"Team UUID scope. Optional when the server was started with a default team."`
}

type billingStatusInput struct{}

type billingStatusOutput struct {
	APIVersion    string         `json:"apiVersion"`
	Viewer        *client.Viewer `json:"viewer,omitempty"`
	CorrelationID string         `json:"correlationId"`
}

type listCustomersInput struct {
	teamScopedInput
	First int    `json:"first,omitempty" jsonschema:"Maximum customers to return (default 20, max 100)."`
	After string `json:"after,omitempty" jsonschema:"Opaque pagination cursor from a previous page."`
}

type listCustomersOutput struct {
	Customers     []client.Customer `json:"customers"`
	HasNextPage   bool              `json:"hasNextPage"`
	EndCursor     string            `json:"endCursor,omitempty"`
	CorrelationID string            `json:"correlationId"`
}

type getCustomerInput struct {
	teamScopedInput
	CustomerID string `json:"customer_id" jsonschema:"Customer UUID."`
}

type customerOutput struct {
	Customer      *client.Customer `json:"customer"`
	CorrelationID string           `json:"correlationId"`
}

type listSubscriptionsInput struct {
	teamScopedInput
	First int    `json:"first,omitempty" jsonschema:"Maximum subscriptions to return (default 20, max 100)."`
	After string `json:"after,omitempty" jsonschema:"Opaque pagination cursor from a previous page."`
}

type listSubscriptionsOutput struct {
	Subscriptions []client.Subscription `json:"subscriptions"`
	HasNextPage   bool                  `json:"hasNextPage"`
	EndCursor     string                `json:"endCursor,omitempty"`
	CorrelationID string                `json:"correlationId"`
}

type getSubscriptionInput struct {
	teamScopedInput
	SubscriptionID string `json:"subscription_id" jsonschema:"Subscription UUID."`
}

type subscriptionOutput struct {
	Subscription  *client.Subscription `json:"subscription"`
	CorrelationID string               `json:"correlationId"`
}

type previewInvoiceInput struct {
	teamScopedInput
	SubscriptionID string `json:"subscription_id" jsonschema:"Subscription UUID to preview."`
	AsOf           string `json:"as_of" jsonschema:"Preview date (YYYY-MM-DD); the billing period containing it is previewed."`
}

type previewInvoiceOutput struct {
	Preview       *client.InvoicePreview `json:"preview"`
	CorrelationID string                 `json:"correlationId"`
}

type getInvoiceInput struct {
	teamScopedInput
	InvoiceIntentID string `json:"invoice_intent_id" jsonschema:"Invoice intent UUID."`
}

type invoiceIntentOutput struct {
	InvoiceIntent *client.InvoiceIntent `json:"invoiceIntent"`
	CorrelationID string                `json:"correlationId"`
}

type getOperationInput struct {
	teamScopedInput
	OperationID string `json:"operation_id" jsonschema:"Durable operation UUID."`
}

type operationOutput struct {
	Operation     *client.Operation `json:"operation"`
	CorrelationID string            `json:"correlationId"`
}

func (s *Server) registerReadTools() {
	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "billing_status",
		Description: "Read-only. Returns the Billing Core API version and the authenticated principal with its organization/team memberships. No side effects.",
		Annotations: readOnly("Billing status"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in billingStatusInput) (*sdk.CallToolResult, billingStatusOutput, error) {
		corr := client.NewCorrelationID()
		status, err := s.cl.Status(ctx, corr)
		if err != nil {
			return nil, billingStatusOutput{}, toolError(err, corr)
		}
		return nil, billingStatusOutput{APIVersion: status.APIVersion, Viewer: status.Viewer, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "list_customers",
		Description: "Read-only. Lists customers of the scoped team as a bounded page. Requires team scope (server default or team_id). No side effects.",
		Annotations: readOnly("List customers"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in listCustomersInput) (*sdk.CallToolResult, listCustomersOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, listCustomersOutput{}, err
		}
		conn, err := s.cl.Customers(ctx, corr, team, boundedFirst(in.First), in.After)
		if err != nil {
			return nil, listCustomersOutput{}, toolError(err, corr)
		}
		out := listCustomersOutput{
			Customers:     make([]client.Customer, 0, len(conn.Edges)),
			HasNextPage:   conn.PageInfo.HasNextPage,
			EndCursor:     conn.PageInfo.EndCursor,
			CorrelationID: corr,
		}
		for _, e := range conn.Edges {
			out.Customers = append(out.Customers, e.Node)
		}
		return nil, out, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "get_customer",
		Description: "Read-only. Fetches one customer of the scoped team by UUID. Requires team scope. No side effects.",
		Annotations: readOnly("Get customer"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in getCustomerInput) (*sdk.CallToolResult, customerOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, customerOutput{}, err
		}
		customer, err := s.cl.Customer(ctx, corr, team, in.CustomerID)
		if err != nil {
			return nil, customerOutput{}, toolError(err, corr)
		}
		return nil, customerOutput{Customer: customer, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "list_subscriptions",
		Description: "Read-only. Lists subscriptions of the scoped team as a bounded page. Requires team scope. No side effects.",
		Annotations: readOnly("List subscriptions"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in listSubscriptionsInput) (*sdk.CallToolResult, listSubscriptionsOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, listSubscriptionsOutput{}, err
		}
		conn, err := s.cl.Subscriptions(ctx, corr, team, boundedFirst(in.First), in.After)
		if err != nil {
			return nil, listSubscriptionsOutput{}, toolError(err, corr)
		}
		out := listSubscriptionsOutput{
			Subscriptions: make([]client.Subscription, 0, len(conn.Edges)),
			HasNextPage:   conn.PageInfo.HasNextPage,
			EndCursor:     conn.PageInfo.EndCursor,
			CorrelationID: corr,
		}
		for _, e := range conn.Edges {
			out.Subscriptions = append(out.Subscriptions, e.Node)
		}
		return nil, out, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "get_subscription",
		Description: "Read-only. Fetches one subscription of the scoped team by UUID, including its lifecycle state. Requires team scope. No side effects.",
		Annotations: readOnly("Get subscription"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in getSubscriptionInput) (*sdk.CallToolResult, subscriptionOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, subscriptionOutput{}, err
		}
		sub, err := s.cl.Subscription(ctx, corr, team, in.SubscriptionID)
		if err != nil {
			return nil, subscriptionOutput{}, toolError(err, corr)
		}
		return nil, subscriptionOutput{Subscription: sub, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "preview_invoice",
		Description: "Read-only. Deterministic, side-effect-free invoice preview for a subscription as of a date, including lines, net amount and freeze blockers. Requires team scope.",
		Annotations: readOnly("Preview invoice"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in previewInvoiceInput) (*sdk.CallToolResult, previewInvoiceOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, previewInvoiceOutput{}, err
		}
		preview, err := s.cl.InvoicePreview(ctx, corr, team, in.SubscriptionID, in.AsOf)
		if err != nil {
			return nil, previewInvoiceOutput{}, toolError(err, corr)
		}
		return nil, previewInvoiceOutput{Preview: preview, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "get_invoice",
		Description: "Read-only. Fetches an immutable invoice intent by UUID, including lifecycle state and lines. Requires team scope. No side effects.",
		Annotations: readOnly("Get invoice intent"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in getInvoiceInput) (*sdk.CallToolResult, invoiceIntentOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, invoiceIntentOutput{}, err
		}
		intent, err := s.cl.InvoiceIntent(ctx, corr, team, in.InvoiceIntentID)
		if err != nil {
			return nil, invoiceIntentOutput{}, toolError(err, corr)
		}
		return nil, invoiceIntentOutput{InvoiceIntent: intent, CorrelationID: corr}, nil
	})

	sdk.AddTool(s.mcp, &sdk.Tool{
		Name:        "get_operation",
		Description: "Read-only. Fetches a durable asynchronous operation by UUID (state, attempts, safe error summary). Use it to follow synchronize/book work. Requires team scope. No side effects.",
		Annotations: readOnly("Get operation"),
	}, func(ctx context.Context, req *sdk.CallToolRequest, in getOperationInput) (*sdk.CallToolResult, operationOutput, error) {
		corr := client.NewCorrelationID()
		team, err := s.team(in.TeamID)
		if err != nil {
			return nil, operationOutput{}, err
		}
		op, err := s.cl.Operation(ctx, corr, team, in.OperationID)
		if err != nil {
			return nil, operationOutput{}, toolError(err, corr)
		}
		return nil, operationOutput{Operation: op, CorrelationID: corr}, nil
	})
}
