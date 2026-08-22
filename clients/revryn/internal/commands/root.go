// Package commands implements the revryn Cobra command tree with stable
// --json output DTOs and the central exit-code mapping
// (SPEC §14.14, §22.10, INV-043; contracts/cli/exit-codes.md).
package commands

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

// Version is the revryn release version, stamped at build time via
// -ldflags "-X github.com/spriz/revryn/clients/revryn/internal/commands.Version=...".
var Version = "0.1.0-dev"

// App carries resolved global configuration and injectable process state so
// commands are unit-testable without touching real stdio or the environment.
type App struct {
	Stdout io.Writer
	Stderr io.Writer
	Getenv func(string) string

	// Resolved global flags.
	URL           string
	Token         string
	Team          string
	CorrelationID string
	JSON          bool

	// Client used by all commands; built in the root PersistentPreRun.
	Client *client.Client
}

// Main runs revryn with process defaults and returns the exit code.
func Main(args []string) int {
	return Execute(args, os.Stdout, os.Stderr, os.Getenv)
}

// Execute runs the command tree and returns the registered exit code
// (contracts/cli/exit-codes.md). Errors are printed to stderr together with
// the correlation ID (SPEC §22.10).
func Execute(args []string, stdout, stderr io.Writer, getenv func(string) string) int {
	app := &App{Stdout: stdout, Stderr: stderr, Getenv: getenv}
	root := app.NewRootCommand()
	root.SetArgs(args)
	root.SetOut(stdout)
	root.SetErr(stderr)
	if err := root.Execute(); err != nil {
		code := ExitCode(err)
		app.printError(err, code)
		return code
	}
	return ExitOK
}

// NewRootCommand builds the revryn command tree bound to app.
func (a *App) NewRootCommand() *cobra.Command {
	var flagURL, flagToken, flagTeam, flagCorrelation string
	var flagJSON bool

	root := &cobra.Command{
		Use:           "revryn",
		Short:         "Official command-line client for Billing Core",
		Long:          "revryn administers and automates Billing Core through its public GraphQL contract (SPEC §12.2.3, INV-043).",
		Version:       Version,
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			a.URL = firstNonEmpty(flagURL, a.Getenv("BILLING_URL"), client.DefaultBaseURL)
			a.Token = firstNonEmpty(flagToken, a.Getenv("BILLING_TOKEN"))
			a.Team = firstNonEmpty(flagTeam, a.Getenv("BILLING_TEAM"))
			a.CorrelationID = firstNonEmpty(flagCorrelation, client.NewCorrelationID())
			a.JSON = flagJSON
			a.Client = client.New(client.Config{BaseURL: a.URL, Token: a.Token, UserAgent: "revryn/" + Version})
			return nil
		},
	}
	root.SetVersionTemplate("revryn {{.Version}}\n")

	pf := root.PersistentFlags()
	pf.StringVar(&flagURL, "url", "", "Billing Core base URL (env BILLING_URL, default "+client.DefaultBaseURL+")")
	pf.StringVar(&flagToken, "token", "", "bearer session token (env BILLING_TOKEN)")
	pf.StringVar(&flagTeam, "team", "", "team UUID scope (env BILLING_TEAM)")
	pf.StringVar(&flagCorrelation, "correlation-id", "", "correlation ID for tracing (generated UUID when absent)")
	pf.BoolVar(&flagJSON, "json", false, "emit stable machine-readable JSON (schema revryn.v1)")

	root.SetFlagErrorFunc(func(cmd *cobra.Command, err error) error {
		return &UsageError{Err: err}
	})

	root.AddCommand(
		a.newStatusCommand(),
		a.newCustomersCommand(),
		a.newSubscriptionsCommand(),
		a.newInvoicesCommand(),
		a.newCreditsCommand(),
		a.newCreditClosesCommand(),
		a.newOperationsCommand(),
		a.newRunsCommand(),
		a.newDoctorCommand(),
		a.newMCPCommand(),
	)
	return root
}

// requireTeam returns the resolved team UUID or a usage error.
func (a *App) requireTeam() (string, error) {
	if a.Team == "" {
		return "", &UsageError{Err: fmt.Errorf("a team UUID is required: pass --team or set BILLING_TEAM")}
	}
	return a.Team, nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
