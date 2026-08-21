package commands

import (
	"github.com/spf13/cobra"

	mcpserver "github.com/revryn/billing-core/internal/mcp"
)

func (a *App) newMCPCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "mcp",
		Short: "Model Context Protocol server for agentic consumers (SPEC §12.2.3, INV-044)",
	}

	serve := &cobra.Command{
		Use:   "serve",
		Short: "Serve semantic Billing Core MCP tools over stdio",
		Long: "Serves the bounded, typed Billing Core MCP tool set over stdio (ADR-027). " +
			"The server uses the resolved --url/--token configuration; --team (or BILLING_TEAM) " +
			"sets the default team scope, which individual tool calls may override via team_id.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			srv := mcpserver.New(mcpserver.Config{
				BaseURL: a.URL,
				Token:   a.Token,
				TeamID:  a.Team,
				Version: Version,
			})
			return srv.RunStdio(cmd.Context())
		},
	}

	cmd.AddCommand(serve)
	return cmd
}
