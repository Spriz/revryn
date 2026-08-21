// Package mcpserver implements the Billing Core MCP server
// (SPEC §12.2.3, BC-US-158, INV-044, ADR-027).
//
// It exposes bounded, semantic billing tools over the official Go MCP SDK.
// It never exposes arbitrary GraphQL, SQL, or shell execution, and every
// mutating tool requires explicit confirmation plus idempotency semantics.
// Tool metadata is documented in contracts/mcp/tools.md.
package mcpserver

import (
	"context"
	"errors"
	"fmt"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/revryn/billing-core/internal/client"
)

// Config configures the MCP server at serve start.
type Config struct {
	// BaseURL of the Billing Core server.
	BaseURL string
	// Token is the bearer session token used for every upstream call.
	Token string
	// TeamID is the default team scope; individual tool calls may override
	// it via their team_id input. Tools that need a team fail without one.
	TeamID string
	// Version reported in the MCP implementation info.
	Version string
	// Client overrides the upstream client (tests); built from BaseURL/Token
	// when nil.
	Client *client.Client
}

// Server wires the Billing Core client into an MCP tool server.
type Server struct {
	cfg Config
	cl  *client.Client
	mcp *sdk.Server
}

// New builds the MCP server and registers the semantic tool set.
func New(cfg Config) *Server {
	cl := cfg.Client
	if cl == nil {
		cl = client.New(client.Config{BaseURL: cfg.BaseURL, Token: cfg.Token, UserAgent: "billingctl-mcp/" + cfg.Version})
	}
	s := &Server{
		cfg: cfg,
		cl:  cl,
		mcp: sdk.NewServer(&sdk.Implementation{
			Name:    "billing-core",
			Title:   "Billing Core",
			Version: cfg.Version,
		}, nil),
	}
	s.registerReadTools()
	s.registerMutatingTools()
	return s
}

// MCP exposes the underlying SDK server (used by tests and alternative
// transports).
func (s *Server) MCP() *sdk.Server { return s.mcp }

// RunStdio serves MCP over stdio until the context is cancelled or the
// client disconnects.
func (s *Server) RunStdio(ctx context.Context) error {
	return s.mcp.Run(ctx, &sdk.StdioTransport{})
}

// team resolves the effective team scope for a call: explicit per-call
// team_id wins, then the server-level default.
func (s *Server) team(override string) (string, error) {
	if override != "" {
		return override, nil
	}
	if s.cfg.TeamID != "" {
		return s.cfg.TeamID, nil
	}
	return "", errors.New("team scope required: pass team_id, or start the server with --team/BILLING_TEAM")
}

// toolError converts client errors into safe MCP tool errors. Typed problem
// messages come from the server and are safe; transport details are reduced
// to a generic summary. The correlation ID is always included so humans can
// find the audit/log trail (SPEC §22.10).
func toolError(err error, correlationID string) error {
	msg := "request failed"
	var problem *client.ProblemError
	var authErr *client.AuthError
	var notFound *client.NotFoundError
	var transport *client.TransportError
	var httpErr *client.HTTPError
	var gql *client.GraphQLError
	switch {
	case errors.As(err, &problem):
		msg = problem.Error()
	case errors.As(err, &authErr):
		msg = "authentication or authorization failed against Billing Core"
	case errors.As(err, &notFound):
		msg = notFound.Error()
	case errors.As(err, &transport):
		msg = fmt.Sprintf("Billing Core unreachable (%d attempts)", transport.Attempts)
	case errors.As(err, &httpErr):
		msg = fmt.Sprintf("Billing Core returned HTTP %d", httpErr.StatusCode)
	case errors.As(err, &gql):
		msg = "Billing Core rejected the request: " + gql.Error()
	default:
		msg = err.Error()
	}
	return fmt.Errorf("%s [correlation-id: %s]", msg, correlationID)
}

// requireConfirm gates consequential financial actions on an explicit
// confirm flag (SPEC §14.14: "potentially consequential financial actions
// use explicit confirmation semantics").
func requireConfirm(confirm bool, action string) error {
	if !confirm {
		return fmt.Errorf("confirmation required: %s is a consequential financial action; call again with confirm=true after verifying the target", action)
	}
	return nil
}

// boundedFirst clamps list page sizes to keep agent output bounded.
func boundedFirst(first int) int {
	const (
		def = 20
		max = 100
	)
	if first <= 0 {
		return def
	}
	if first > max {
		return max
	}
	return first
}

func ptr[T any](v T) *T { return &v }
