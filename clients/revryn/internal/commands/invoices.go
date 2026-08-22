package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

func (a *App) newInvoicesCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "invoices",
		Short: "Preview, freeze and drive invoice intents through their lifecycle",
	}
	cmd.AddCommand(
		a.newInvoicesPreviewCommand(),
		a.newInvoicesFreezeCommand(),
		a.newInvoicesGetCommand(),
		a.newInvoicesSyncCommand(),
		a.newInvoicesApproveCommand(),
		a.newInvoicesBookCommand(),
	)
	return cmd
}

func (a *App) newInvoicesPreviewCommand() *cobra.Command {
	var subscriptionID, asOf string
	cmd := &cobra.Command{
		Use:   "preview",
		Short: "Deterministic, side-effect-free invoice preview (BC-US-068)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			if err := validateDate("as-of", asOf); err != nil {
				return err
			}
			preview, err := a.Client.InvoicePreview(cmd.Context(), a.CorrelationID, team, subscriptionID, asOf)
			if err != nil {
				return err
			}
			return a.emit(preview, func(w io.Writer) {
				kv(w, [][2]string{
					{"subscription", preview.SubscriptionID},
					{"customer", preview.CustomerID},
					{"contract", preview.ContractID},
					{"invoice date", preview.InvoiceDate},
					{"period", preview.PeriodStart + " .. " + preview.PeriodEndExclusive + " (excl)"},
					{"net amount", fmt.Sprintf("%d %s (minor units)", preview.NetAmountMinor, preview.Currency)},
					{"fingerprint", preview.Fingerprint},
				})
				if len(preview.Blockers) > 0 {
					fmt.Fprintln(w, "\nfreeze blockers:")
					for _, b := range preview.Blockers {
						fmt.Fprintf(w, "  - %s\n", b)
					}
				}
				fmt.Fprintln(w, "\nlines:")
				rows := make([][]string, 0, len(preview.Lines))
				for _, l := range preview.Lines {
					rows = append(rows, []string{
						fmt.Sprint(l.Ordinal), l.LineKey, l.Description, l.Quantity,
						fmt.Sprint(l.AmountMinor), l.RecognitionMode, serviceRange(l.ServiceStart, l.ServiceEndExclusive),
					})
				}
				table(w, []string{"ORD", "LINE KEY", "DESCRIPTION", "QTY", "AMOUNT (MINOR)", "RECOGNITION", "SERVICE"}, rows)
			})
		},
	}
	cmd.Flags().StringVar(&subscriptionID, "subscription", "", "subscription UUID (required)")
	cmd.Flags().StringVar(&asOf, "as-of", "", "preview date YYYY-MM-DD (required)")
	_ = cmd.MarkFlagRequired("subscription")
	_ = cmd.MarkFlagRequired("as-of")
	return cmd
}

func (a *App) newInvoicesFreezeCommand() *cobra.Command {
	var subscriptionID, asOf, billingRunID, idempotencyKey string
	cmd := &cobra.Command{
		Use:   "freeze",
		Short: "Freeze the preview into an immutable invoice intent (freezeInvoiceIntent)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			if err := validateDate("as-of", asOf); err != nil {
				return err
			}
			intent, err := a.Client.FreezeInvoiceIntent(cmd.Context(), a.CorrelationID, client.FreezeInvoiceIntentInput{
				TeamID:         team,
				SubscriptionID: subscriptionID,
				AsOf:           asOf,
				BillingRunID:   billingRunID,
				IdempotencyKey: idempotencyKey,
			})
			if err != nil {
				return err
			}
			return a.emit(intent, func(w io.Writer) {
				fmt.Fprintln(w, "invoice intent frozen")
				printInvoiceIntent(w, intent)
			})
		},
	}
	cmd.Flags().StringVar(&subscriptionID, "subscription", "", "subscription UUID (required)")
	cmd.Flags().StringVar(&asOf, "as-of", "", "preview date YYYY-MM-DD (required)")
	cmd.Flags().StringVar(&billingRunID, "billing-run", "", "billing run UUID to attach the intent to")
	cmd.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	_ = cmd.MarkFlagRequired("subscription")
	_ = cmd.MarkFlagRequired("as-of")
	return cmd
}

func (a *App) newInvoicesGetCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "get <intent-id>",
		Short: "Show an invoice intent including state and lines",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			intent, err := a.Client.InvoiceIntent(cmd.Context(), a.CorrelationID, team, args[0])
			if err != nil {
				return err
			}
			return a.emit(intent, func(w io.Writer) { printInvoiceIntent(w, intent) })
		},
	}
}

func (a *App) newInvoicesSyncCommand() *cobra.Command {
	var idempotencyKey string
	cmd := &cobra.Command{
		Use:   "sync <intent-id>",
		Short: "Enqueue ERP draft synchronization (synchronizeInvoice)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			op, err := a.Client.SynchronizeInvoice(cmd.Context(), a.CorrelationID, client.SynchronizeInvoiceInput{
				TeamID:          team,
				InvoiceIntentID: args[0],
				IdempotencyKey:  idempotencyKey,
			})
			if err != nil {
				return err
			}
			return a.emit(op, func(w io.Writer) {
				fmt.Fprintln(w, "synchronization accepted; follow the durable operation")
				printOperation(w, op)
			})
		},
	}
	cmd.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	return cmd
}

func (a *App) newInvoicesApproveCommand() *cobra.Command {
	var reason string
	cmd := &cobra.Command{
		Use:   "approve <intent-id>",
		Short: "Approve a reconciled ERP draft for booking (approveInvoice)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			intent, err := a.Client.ApproveInvoice(cmd.Context(), a.CorrelationID, client.ApproveInvoiceInput{
				TeamID:          team,
				InvoiceIntentID: args[0],
				Reason:          reason,
			})
			if err != nil {
				return err
			}
			return a.emit(intent, func(w io.Writer) {
				fmt.Fprintln(w, "invoice approved")
				printInvoiceIntent(w, intent)
			})
		},
	}
	cmd.Flags().StringVar(&reason, "reason", "", "optional approval reason for the audit trail")
	return cmd
}

func (a *App) newInvoicesBookCommand() *cobra.Command {
	var idempotencyKey string
	cmd := &cobra.Command{
		Use:   "book <intent-id>",
		Short: "Enqueue booking of an approved draft (bookInvoice)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			op, err := a.Client.BookInvoice(cmd.Context(), a.CorrelationID, client.BookInvoiceInput{
				TeamID:          team,
				InvoiceIntentID: args[0],
				IdempotencyKey:  idempotencyKey,
			})
			if err != nil {
				return err
			}
			return a.emit(op, func(w io.Writer) {
				fmt.Fprintln(w, "booking accepted; follow the durable operation")
				printOperation(w, op)
			})
		},
	}
	cmd.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	return cmd
}

func printInvoiceIntent(w io.Writer, in *client.InvoiceIntent) {
	kv(w, [][2]string{
		{"id", in.ID},
		{"state", in.State},
		{"document kind", in.DocumentKind},
		{"customer", in.CustomerID + " (v" + fmt.Sprint(in.CustomerVersion) + ")"},
		{"contract", dash(in.ContractID)},
		{"billing run", dash(in.BillingRunID)},
		{"invoice date", in.InvoiceDate},
		{"intent version", fmt.Sprint(in.IntentVersion)},
		{"supersedes", dash(in.SupersedesInvoiceIntentID)},
		{"net amount", fmt.Sprintf("%d %s (minor units)", in.NetAmountMinor, in.Currency)},
		{"content hash", in.ContentHash},
		{"frozen at", dash(in.FrozenAt)},
	})
	fmt.Fprintln(w, "\nlines:")
	rows := make([][]string, 0, len(in.Lines))
	for _, l := range in.Lines {
		rows = append(rows, []string{
			fmt.Sprint(l.Ordinal), l.LineKey, l.Description, l.Quantity,
			fmt.Sprintf("%d %s", l.AmountMinor, l.Currency), l.RecognitionMode, serviceRange(l.ServiceStart, l.ServiceEndExclusive),
		})
	}
	table(w, []string{"ORD", "LINE KEY", "DESCRIPTION", "QTY", "AMOUNT (MINOR)", "RECOGNITION", "SERVICE"}, rows)
}

func printOperation(w io.Writer, op *client.Operation) {
	kv(w, [][2]string{
		{"operation", op.ID},
		{"type", op.Type},
		{"state", op.State},
		{"attempts", fmt.Sprint(op.AttemptCount)},
		{"error class", dash(op.ErrorClass)},
		{"safe error", dash(joinNonEmpty(op.SafeErrorCode, op.SafeErrorSummary))},
		{"blocked reason", dash(op.BlockedReason)},
		{"next attempt", dash(op.NextAttemptAt)},
		{"correlation", dash(op.CorrelationID)},
		{"started at", dash(op.StartedAt)},
		{"finished at", dash(op.FinishedAt)},
	})
}

func serviceRange(start, endExclusive string) string {
	if start == "" && endExclusive == "" {
		return "-"
	}
	return dash(start) + " .. " + dash(endExclusive)
}

func joinNonEmpty(parts ...string) string {
	out := ""
	for _, p := range parts {
		if p == "" {
			continue
		}
		if out != "" {
			out += ": "
		}
		out += p
	}
	return out
}
