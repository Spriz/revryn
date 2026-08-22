package commands

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

func (a *App) newCreditClosesCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "credit-closes",
		Short: "Freeze, approve, post and accept monthly customer-credit closes",
		Long: "One immutable close per currency and calendar month bridges the detailed " +
			"customer-credit subledger to a single aggregate ERP liability voucher " +
			"(BC-US-163..165).",
	}
	cmd.AddCommand(
		a.newCreditClosesListCommand(),
		a.newCreditClosesGetCommand(),
		a.newCreditClosesPoliciesCommand(),
		a.newCreditClosesCreatePolicyCommand(),
		a.newCreditClosesGenerateCommand(),
		a.newCreditClosesApproveCommand(),
		a.newCreditClosesPostCommand(),
		a.newCreditClosesAcceptCommand(),
		a.newCreditClosesReportCommand(),
		a.newCreditClosesReverseCommand(),
		a.newCreditClosesReplaceCommand(),
	)
	return cmd
}

func printCreditClose(w io.Writer, close *client.CreditClose) {
	rows := [][2]string{
		{"id", close.ID},
		{"state", close.State},
	}
	if close.CloseKind != "" && close.CloseKind != "regular" {
		rows = append(rows, [2]string{"kind", close.CloseKind})
		if close.ReversalOfCloseID != nil {
			rows = append(rows, [2]string{"corrects close", *close.ReversalOfCloseID})
		}
	}
	rows = append(rows,
		[2]string{"period", close.PeriodStart + " .. " + close.PeriodEndExclusive + " (excl)"},
		[2]string{"currency", close.Currency},
		[2]string{"cutoff", close.TransactionCutoff},
	)
	if close.OpeningMinor != nil && close.ClosingMinor != nil && close.NetChangeMinor != nil {
		rows = append(rows,
			[2]string{"opening", fmt.Sprintf("%d %s (minor units)", *close.OpeningMinor, close.Currency)},
			[2]string{"net change", fmt.Sprintf("%d %s (minor units)", *close.NetChangeMinor, close.Currency)},
			[2]string{"closing", fmt.Sprintf("%d %s (minor units)", *close.ClosingMinor, close.Currency)},
		)
	}
	if close.ReportSha256 != nil {
		rows = append(rows, [2]string{"report sha256", *close.ReportSha256})
	}
	if close.ExternalVoucherNumber != nil {
		rows = append(rows, [2]string{"erp voucher", *close.ExternalVoucherNumber})
	}
	if close.ClosedAt != nil {
		rows = append(rows, [2]string{"closed at", *close.ClosedAt})
	}
	kv(w, rows)

	if len(close.Movements) > 0 {
		fmt.Fprintln(w, "\nmovements:")
		moveRows := make([][]string, 0, len(close.Movements))
		for _, m := range close.Movements {
			moveRows = append(moveRows, []string{
				m.MovementType, fmt.Sprint(m.TransactionCount),
				fmt.Sprint(m.AmountMinor), fmt.Sprint(m.LiabilityEffectMinor),
			})
		}
		table(w, []string{"TYPE", "TXNS", "AMOUNT (MINOR)", "LIABILITY EFFECT"}, moveRows)
	}
	if len(close.Evidence) > 0 {
		fmt.Fprintln(w, "\nevidence:")
		evRows := make([][]string, 0, len(close.Evidence))
		for _, e := range close.Evidence {
			evRows = append(evRows, []string{e.EvidenceType, e.ContentType, fmt.Sprint(e.ByteSize), e.Sha256})
		}
		table(w, []string{"TYPE", "CONTENT TYPE", "BYTES", "SHA-256"}, evRows)
	}
}

func (a *App) newCreditClosesListCommand() *cobra.Command {
	var currency, state string
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List the team's monthly closes, newest period first",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			closes, err := a.Client.CreditCloses(cmd.Context(), a.CorrelationID, team, currency, state)
			if err != nil {
				return err
			}
			return a.emit(closes, func(w io.Writer) {
				rows := make([][]string, 0, len(closes))
				for _, c := range closes {
					closing := ""
					if c.ClosingMinor != nil {
						closing = fmt.Sprint(*c.ClosingMinor)
					}
					rows = append(rows, []string{
						c.ID, c.PeriodStart, c.Currency, c.State, closing,
					})
				}
				table(w, []string{"ID", "PERIOD START", "CURRENCY", "STATE", "CLOSING (MINOR)"}, rows)
			})
		},
	}
	cmd.Flags().StringVar(&currency, "currency", "", "filter by currency code")
	cmd.Flags().StringVar(&state, "state", "", "filter by lifecycle state")
	return cmd
}

func (a *App) newCreditClosesGetCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "get <close-id>",
		Short: "Show one close with movements and evidence hashes",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			close, err := a.Client.CreditClose(cmd.Context(), a.CorrelationID, team, args[0])
			if err != nil {
				return err
			}
			return a.emit(close, func(w io.Writer) { printCreditClose(w, close) })
		},
	}
	return cmd
}

func (a *App) newCreditClosesPoliciesCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "policies",
		Short: "List posting-policy versions, newest first",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			policies, err := a.Client.CreditClosePolicies(cmd.Context(), a.CorrelationID, team)
			if err != nil {
				return err
			}
			return a.emit(policies, func(w io.Writer) {
				rows := make([][]string, 0, len(policies))
				for _, p := range policies {
					offset := ""
					if p.DefaultOffsetAccountNumber != nil {
						offset = fmt.Sprint(*p.DefaultOffsetAccountNumber)
					}
					rows = append(rows, []string{
						fmt.Sprint(p.Version), p.EffectiveFrom, fmt.Sprint(p.JournalNumber),
						fmt.Sprint(p.LiabilityAccountNumber), offset, p.PostingMode, p.SettlementMode,
					})
				}
				table(w, []string{"VERSION", "EFFECTIVE", "JOURNAL", "LIABILITY ACCT", "OFFSET ACCT", "MODE", "SETTLEMENT"}, rows)
			})
		},
	}
	return cmd
}

func (a *App) newCreditClosesCreatePolicyCommand() *cobra.Command {
	var effectiveFrom, settlementMode string
	var journal, liabilityAccount, offsetAccount int
	var clearingAccount, contraAccount int
	var postZeroDelta bool
	cmd := &cobra.Command{
		Use:   "create-policy",
		Short: "Create an accountant-approved posting-policy version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			if err := validateDate("effective-from", effectiveFrom); err != nil {
				return err
			}
			input := client.CreateCreditClosePolicyInput{
				TeamID:                     team,
				EffectiveFrom:              effectiveFrom,
				JournalNumber:              journal,
				LiabilityAccountNumber:     liabilityAccount,
				DefaultOffsetAccountNumber: offsetAccount,
				PostZeroDelta:              postZeroDelta,
				SettlementMode:             settlementMode,
			}
			if clearingAccount > 0 {
				input.SettlementClearingAccount = &clearingAccount
			}
			if contraAccount > 0 {
				input.SettlementContraAccount = &contraAccount
			}
			policy, err := a.Client.CreateCreditClosePolicy(cmd.Context(), a.CorrelationID, input)
			if err != nil {
				return err
			}
			return a.emit(policy, func(w io.Writer) {
				fmt.Fprintln(w, "posting policy created")
				kv(w, [][2]string{
					{"id", policy.ID},
					{"version", fmt.Sprint(policy.Version)},
					{"effective from", policy.EffectiveFrom},
					{"journal", fmt.Sprint(policy.JournalNumber)},
					{"liability account", fmt.Sprint(policy.LiabilityAccountNumber)},
				})
			})
		},
	}
	cmd.Flags().StringVar(&effectiveFrom, "effective-from", "", "first period start date YYYY-MM-DD (required)")
	cmd.Flags().IntVar(&journal, "journal", 0, "e-conomic journal number (required)")
	cmd.Flags().IntVar(&liabilityAccount, "liability-account", 0, "liability account number (required)")
	cmd.Flags().IntVar(&offsetAccount, "offset-account", 0, "single offset account number (required)")
	cmd.Flags().BoolVar(&postZeroDelta, "post-zero-delta", false, "post months with zero net change to the ERP")
	cmd.Flags().StringVar(&settlementMode, "settlement-mode", "", "receivable-settlement mode: none, erp_customer_settlement, or external_reference (SPEC §9.4.1)")
	cmd.Flags().IntVar(&clearingAccount, "settlement-clearing-account", 0, "clearing account number (required for erp_customer_settlement)")
	cmd.Flags().IntVar(&contraAccount, "settlement-contra-account", 0, "contra account number (required for erp_customer_settlement)")
	_ = cmd.MarkFlagRequired("effective-from")
	_ = cmd.MarkFlagRequired("journal")
	_ = cmd.MarkFlagRequired("liability-account")
	_ = cmd.MarkFlagRequired("offset-account")
	return cmd
}

func (a *App) newCreditClosesGenerateCommand() *cobra.Command {
	var currency, periodDate, policyVersionID, idempotencyKey string
	var bootstrapOpening int64
	var bootstrapSet bool
	cmd := &cobra.Command{
		Use:   "generate",
		Short: "Freeze one deterministic close for a currency and calendar month",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			if err := validateDate("period-date", periodDate); err != nil {
				return err
			}
			input := client.GenerateCreditCloseInput{
				TeamID:          team,
				Currency:        currency,
				PeriodDate:      periodDate,
				PolicyVersionID: policyVersionID,
				IdempotencyKey:  idempotencyKey,
			}
			bootstrapSet = cmd.Flags().Changed("bootstrap-opening-minor")
			if bootstrapSet {
				input.BootstrapOpeningMinor = &bootstrapOpening
			}
			close, err := a.Client.GenerateCreditClose(cmd.Context(), a.CorrelationID, input)
			if err != nil {
				return err
			}
			return a.emit(close, func(w io.Writer) {
				fmt.Fprintln(w, "credit close frozen")
				printCreditClose(w, close)
			})
		},
	}
	cmd.Flags().StringVar(&currency, "currency", "", "currency code (required)")
	cmd.Flags().StringVar(&periodDate, "period-date", "", "any date in the close month YYYY-MM-DD (required)")
	cmd.Flags().Int64Var(&bootstrapOpening, "bootstrap-opening-minor", 0, "opening balance in minor units, first close only (zero is valid)")
	cmd.Flags().StringVar(&policyVersionID, "policy-version", "", "policy version UUID (defaults to the latest)")
	cmd.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	_ = cmd.MarkFlagRequired("currency")
	_ = cmd.MarkFlagRequired("period-date")
	return cmd
}

func (a *App) newCreditClosesApproveCommand() *cobra.Command {
	var reason string
	cmd := &cobra.Command{
		Use:   "approve <close-id>",
		Short: "Approve the exact frozen report hash for ERP posting",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			close, err := a.Client.ApproveCreditClose(cmd.Context(), a.CorrelationID, client.ApproveCreditCloseInput{
				TeamID:        team,
				CreditCloseID: args[0],
				Reason:        reason,
			})
			if err != nil {
				return err
			}
			return a.emit(close, func(w io.Writer) {
				fmt.Fprintln(w, "credit close approved")
				printCreditClose(w, close)
			})
		},
	}
	cmd.Flags().StringVar(&reason, "reason", "", "approval reason recorded on the close")
	return cmd
}

func (a *App) newCreditClosesPostCommand() *cobra.Command {
	var idempotencyKey string
	cmd := &cobra.Command{
		Use:   "post <close-id>",
		Short: "Create the durable, idempotent ERP posting operation",
		Long: "Posting searches the provider by stable reference before it ever creates the " +
			"aggregate voucher, attaches the report, and reconciles the authoritative " +
			"read-back — no duplicate voucher is possible.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			posting, err := a.Client.RequestCreditClosePosting(cmd.Context(), a.CorrelationID, client.RequestCreditClosePostingInput{
				TeamID:         team,
				CreditCloseID:  args[0],
				IdempotencyKey: idempotencyKey,
			})
			if err != nil {
				return err
			}
			return a.emit(posting, func(w io.Writer) {
				fmt.Fprintln(w, "posting requested — follow the durable operation")
				if posting.Operation != nil {
					kv(w, [][2]string{
						{"operation", posting.Operation.ID},
						{"type", posting.Operation.Type},
						{"state", posting.Operation.State},
					})
				}
				if posting.CreditClose != nil {
					fmt.Fprintln(w, "")
					printCreditClose(w, posting.CreditClose)
				}
			})
		},
	}
	cmd.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	return cmd
}

func (a *App) newCreditClosesAcceptCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "accept <close-id>",
		Short: "Accept a fully reconciled close as the authoritative period close",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			close, err := a.Client.CloseCreditPeriod(cmd.Context(), a.CorrelationID, client.CloseCreditPeriodInput{
				TeamID:        team,
				CreditCloseID: args[0],
			})
			if err != nil {
				return err
			}
			return a.emit(close, func(w io.Writer) {
				fmt.Fprintln(w, "period closed")
				printCreditClose(w, close)
			})
		},
	}
	return cmd
}

func (a *App) newCreditClosesReportCommand() *cobra.Command {
	var evidenceType, outPath string
	cmd := &cobra.Command{
		Use:   "report <close-id>",
		Short: "Download one immutable evidence file with its exact bytes",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			report, err := a.Client.CreditCloseReport(cmd.Context(), a.CorrelationID, team, args[0], evidenceType)
			if err != nil {
				return err
			}
			data, err := report.Bytes()
			if err != nil {
				return err
			}
			if outPath != "" {
				if err := os.WriteFile(outPath, data, 0o644); err != nil {
					return fmt.Errorf("write %s: %w", outPath, err)
				}
			}
			summary := struct {
				EvidenceType string `json:"evidenceType"`
				Sha256       string `json:"sha256"`
				ContentType  string `json:"contentType"`
				ByteSize     int    `json:"byteSize"`
				WrittenTo    string `json:"writtenTo,omitempty"`
			}{report.EvidenceType, report.Sha256, report.ContentType, len(data), outPath}
			return a.emit(summary, func(w io.Writer) {
				kv(w, [][2]string{
					{"evidence type", summary.EvidenceType},
					{"content type", summary.ContentType},
					{"bytes", fmt.Sprint(summary.ByteSize)},
					{"sha256", summary.Sha256},
					{"written to", orDash(outPath)},
				})
			})
		},
	}
	cmd.Flags().StringVar(&evidenceType, "type", "pdf_summary", "evidence type (canonical_json, csv_detail, pdf_summary, manifest, erp_voucher, erp_attachment, reconciliation)")
	cmd.Flags().StringVar(&outPath, "out", "", "write the exact evidence bytes to this file")
	return cmd
}

func (a *App) newCreditClosesReverseCommand() *cobra.Command {
	var reason string
	cmd := &cobra.Command{
		Use:   "reverse <close-id>",
		Short: "Freeze a compensating reversal close for an accepted close (ADR-031)",
		Long: "The reversal carries the mirrored bridge (opening/closing swapped, deltas " +
			"negated); approving and posting its voucher cancels the original in the general " +
			"ledger, after which the original close becomes reversed.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			close, err := a.Client.RequestCreditCloseReversal(cmd.Context(), a.CorrelationID, client.RequestCreditCloseReversalInput{
				TeamID:        team,
				CreditCloseID: args[0],
				Reason:        reason,
			})
			if err != nil {
				return err
			}
			return a.emit(close, func(w io.Writer) {
				fmt.Fprintln(w, "reversal close frozen — approve and post it to cancel the original voucher")
				printCreditClose(w, close)
			})
		},
	}
	cmd.Flags().StringVar(&reason, "reason", "", "recorded correction reason (required)")
	_ = cmd.MarkFlagRequired("reason")
	return cmd
}

func (a *App) newCreditClosesReplaceCommand() *cobra.Command {
	var policyVersionID, reason string
	cmd := &cobra.Command{
		Use:   "replace <reversed-close-id>",
		Short: "Freeze a replacement close for a reversed period under a corrected policy (ADR-031)",
		Long: "The replacement reproduces the reversed close's exact frozen figures — recomputed " +
			"from the immutable transaction membership and hash-verified — under the corrected " +
			"policy, then runs the ordinary approve/post/accept flow.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			close, err := a.Client.GenerateCreditCloseReplacement(cmd.Context(), a.CorrelationID, client.GenerateCreditCloseReplacementInput{
				TeamID:          team,
				CreditCloseID:   args[0],
				PolicyVersionID: policyVersionID,
				Reason:          reason,
			})
			if err != nil {
				return err
			}
			return a.emit(close, func(w io.Writer) {
				fmt.Fprintln(w, "replacement close frozen with the exact original figures")
				printCreditClose(w, close)
			})
		},
	}
	cmd.Flags().StringVar(&policyVersionID, "policy-version", "", "corrected posting-policy version UUID (required)")
	cmd.Flags().StringVar(&reason, "reason", "", "recorded correction reason (required)")
	_ = cmd.MarkFlagRequired("policy-version")
	_ = cmd.MarkFlagRequired("reason")
	return cmd
}

func orDash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}
