package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

func (a *App) newRunsCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "runs",
		Short: "Open and inspect billing runs",
	}

	var (
		date           string
		runKey         string
		usageCutoff    string
		idempotencyKey string
	)
	create := &cobra.Command{
		Use:   "create",
		Short: "Open (or return) a billing run by stable run key (createBillingRun)",
		Long: "Opens a billing run for the given invoice date. The run key defaults to run-<date> " +
			"and the usage cutoff to <date>T00:00:00Z; reopening the same key returns the existing run (SPEC §18.1).",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			if err := validateDate("date", date); err != nil {
				return err
			}
			if runKey == "" {
				runKey = "run-" + date
			}
			if usageCutoff == "" {
				usageCutoff = date + "T00:00:00Z"
			}
			run, err := a.Client.CreateBillingRun(cmd.Context(), a.CorrelationID, client.CreateBillingRunInput{
				TeamID:         team,
				RunKey:         runKey,
				InvoiceDate:    date,
				UsageCutoff:    usageCutoff,
				IdempotencyKey: idempotencyKey,
			})
			if err != nil {
				return err
			}
			return a.emit(run, func(w io.Writer) {
				fmt.Fprintln(w, "billing run open")
				printBillingRun(w, run)
			})
		},
	}
	create.Flags().StringVar(&date, "date", "", "invoice date YYYY-MM-DD (required)")
	create.Flags().StringVar(&runKey, "run-key", "", "stable run key (default run-<date>)")
	create.Flags().StringVar(&usageCutoff, "usage-cutoff", "", "usage cutoff ISO 8601 UTC timestamp (default <date>T00:00:00Z)")
	create.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	_ = create.MarkFlagRequired("date")

	get := &cobra.Command{
		Use:   "get <id>",
		Short: "Show a billing run",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			run, err := a.Client.BillingRun(cmd.Context(), a.CorrelationID, team, args[0])
			if err != nil {
				return err
			}
			return a.emit(run, func(w io.Writer) { printBillingRun(w, run) })
		},
	}

	cmd.AddCommand(create, get)
	return cmd
}

func printBillingRun(w io.Writer, r *client.BillingRun) {
	kv(w, [][2]string{
		{"id", r.ID},
		{"run key", r.RunKey},
		{"status", r.Status},
		{"invoice date", r.InvoiceDate},
		{"usage cutoff", r.UsageCutoff},
		{"engine version", r.EngineVersion},
		{"started at", dash(r.StartedAt)},
		{"closed at", dash(r.ClosedAt)},
	})
}
