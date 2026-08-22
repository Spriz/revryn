package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

func (a *App) newCreditsCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "credits",
		Short: "Customer-credit subledger: balances, grants, dispositions, settlements",
		Long: "Customer credit is money-like settlement value, never a discount (INV-050). " +
			"Accounts project the append-only ledger; settlements clear credit-covered " +
			"receivables exactly once (SPEC §9.4.1).",
	}
	cmd.AddCommand(
		a.newCreditsAccountsCommand(),
		a.newCreditsGrantCommand(),
		a.newCreditsSetDispositionCommand(),
		a.newCreditsSettlementsCommand(),
		a.newCreditsSettleExternalCommand(),
	)
	return cmd
}

func (a *App) newCreditsAccountsCommand() *cobra.Command {
	var customerID string
	cmd := &cobra.Command{
		Use:   "accounts",
		Short: "List a customer's credit accounts with grants and transactions",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			accounts, err := a.Client.CreditAccounts(cmd.Context(), a.CorrelationID, team, customerID)
			if err != nil {
				return err
			}
			return a.emit(accounts, func(w io.Writer) {
				for i, account := range accounts {
					if i > 0 {
						fmt.Fprintln(w)
					}
					printCreditAccount(w, &account)
				}
				if len(accounts) == 0 {
					fmt.Fprintln(w, "no credit accounts")
				}
			})
		},
	}
	cmd.Flags().StringVar(&customerID, "customer-id", "", "customer UUID (required)")
	_ = cmd.MarkFlagRequired("customer-id")
	return cmd
}

func printCreditAccount(w io.Writer, account *client.CreditAccount) {
	rows := [][2]string{
		{"id", account.ID},
		{"commercial account", account.AccountID},
		{"currency", account.Currency},
		{"available", fmt.Sprintf("%d %s (minor units)", account.AvailableMinor, account.Currency)},
		{"reserved", fmt.Sprintf("%d %s (minor units)", account.ReservedMinor, account.Currency)},
	}
	if p := account.DispositionPolicy; p != nil {
		policy := p.Policy
		if p.ExpireAfterDays != nil {
			policy = fmt.Sprintf("%s (%d days)", p.Policy, *p.ExpireAfterDays)
		}
		rows = append(rows, [2]string{"disposition", fmt.Sprintf("%s, v%d", policy, p.Version)})
	}
	kv(w, rows)

	if len(account.Grants) > 0 {
		fmt.Fprintln(w, "\ngrants:")
		grantRows := make([][]string, 0, len(account.Grants))
		for _, g := range account.Grants {
			expires := ""
			if g.ExpiresAt != nil {
				expires = *g.ExpiresAt
			}
			grantRows = append(grantRows, []string{
				g.ID, g.OriginType, fmt.Sprint(g.GrantedMinor), fmt.Sprint(g.RemainingMinor),
				g.Status, expires,
			})
		}
		table(w, []string{"ID", "ORIGIN", "GRANTED", "REMAINING", "STATUS", "EXPIRES"}, grantRows)
	}
	if len(account.Transactions) > 0 {
		fmt.Fprintln(w, "\ntransactions:")
		txRows := make([][]string, 0, len(account.Transactions))
		for _, t := range account.Transactions {
			reason := ""
			if t.ReasonCode != nil {
				reason = *t.ReasonCode
			}
			txRows = append(txRows, []string{
				t.TransactionType, fmt.Sprint(t.AmountMinor), t.AccountingEffectiveOn, reason,
			})
		}
		table(w, []string{"TYPE", "AMOUNT (MINOR)", "EFFECTIVE", "REASON"}, txRows)
	}
}

func (a *App) newCreditsGrantCommand() *cobra.Command {
	var accountID, originType, currency, reasonCode, idempotencyKey string
	var amountMinor int64
	cmd := &cobra.Command{
		Use:   "grant",
		Short: "Grant customer credit into the subledger (a liability, never a discount)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			grant, err := a.Client.GrantCredit(cmd.Context(), a.CorrelationID, client.GrantCreditInput{
				TeamID:          team,
				CreditAccountID: accountID,
				OriginType:      originType,
				AmountMinor:     amountMinor,
				Currency:        currency,
				ReasonCode:      reasonCode,
				IdempotencyKey:  idempotencyKey,
			})
			if err != nil {
				return err
			}
			return a.emit(grant, func(w io.Writer) {
				fmt.Fprintln(w, "credit granted")
				kv(w, [][2]string{
					{"grant id", grant.ID},
					{"origin", grant.OriginType},
					{"granted", fmt.Sprintf("%d %s (minor units)", grant.GrantedMinor, grant.Currency)},
					{"status", grant.Status},
				})
			})
		},
	}
	cmd.Flags().StringVar(&accountID, "account-id", "", "credit account UUID (required)")
	cmd.Flags().StringVar(&originType, "origin-type", "goodwill", "unused_prepaid_service, goodwill, external_correction, or manual")
	cmd.Flags().Int64Var(&amountMinor, "amount-minor", 0, "amount in integer minor units (required)")
	cmd.Flags().StringVar(&currency, "currency", "", "ISO currency code (required)")
	cmd.Flags().StringVar(&reasonCode, "reason-code", "", "optional reason code")
	cmd.Flags().StringVar(&idempotencyKey, "idempotency-key", "", "stable retry key (required)")
	_ = cmd.MarkFlagRequired("account-id")
	_ = cmd.MarkFlagRequired("amount-minor")
	_ = cmd.MarkFlagRequired("currency")
	_ = cmd.MarkFlagRequired("idempotency-key")
	return cmd
}

func (a *App) newCreditsSetDispositionCommand() *cobra.Command {
	var accountID, policy string
	var expireAfterDays int
	cmd := &cobra.Command{
		Use:   "set-disposition",
		Short: "Set the versioned remaining-credit disposition policy (BC-US-109)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			input := client.SetCreditDispositionPolicyInput{
				TeamID:          team,
				CreditAccountID: accountID,
				Policy:          policy,
			}
			if expireAfterDays > 0 {
				input.ExpireAfterDays = &expireAfterDays
			}
			set, err := a.Client.SetCreditDispositionPolicy(cmd.Context(), a.CorrelationID, input)
			if err != nil {
				return err
			}
			return a.emit(set, func(w io.Writer) {
				fmt.Fprintln(w, "disposition policy set")
				rows := [][2]string{
					{"policy", set.Policy},
					{"version", fmt.Sprint(set.Version)},
					{"effective from", set.EffectiveFrom},
				}
				if set.ExpireAfterDays != nil {
					rows = append(rows, [2]string{"expire after", fmt.Sprintf("%d days", *set.ExpireAfterDays)})
				}
				kv(w, rows)
			})
		},
	}
	cmd.Flags().StringVar(&accountID, "account-id", "", "credit account UUID (required)")
	cmd.Flags().StringVar(&policy, "policy", "", "retain, refund, or expire_after (required)")
	cmd.Flags().IntVar(&expireAfterDays, "expire-after-days", 0, "required for expire_after")
	_ = cmd.MarkFlagRequired("account-id")
	_ = cmd.MarkFlagRequired("policy")
	return cmd
}

func (a *App) newCreditsSettlementsCommand() *cobra.Command {
	var invoiceIntentID, state string
	cmd := &cobra.Command{
		Use:   "settlements",
		Short: "List receivable settlements opened by credit applications (SPEC §9.4.1)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			settlements, err := a.Client.CreditSettlements(cmd.Context(), a.CorrelationID, team, invoiceIntentID, state)
			if err != nil {
				return err
			}
			return a.emit(settlements, func(w io.Writer) {
				rows := make([][]string, 0, len(settlements))
				for _, s := range settlements {
					evidence := ""
					if s.ExternalReference != nil {
						evidence = *s.ExternalReference
					}
					if s.ExternalVoucherNumber != nil {
						evidence = "voucher " + *s.ExternalVoucherNumber
					}
					rows = append(rows, []string{
						s.ID, s.InvoiceIntentID, fmt.Sprint(s.AmountMinor), s.Currency,
						s.Mode, s.State, evidence,
					})
				}
				table(w, []string{"ID", "INVOICE INTENT", "AMOUNT (MINOR)", "CURRENCY", "MODE", "STATE", "EVIDENCE"}, rows)
			})
		},
	}
	cmd.Flags().StringVar(&invoiceIntentID, "invoice-intent-id", "", "filter by invoice intent UUID")
	cmd.Flags().StringVar(&state, "state", "", "filter by state: pending or reconciled")
	return cmd
}

func (a *App) newCreditsSettleExternalCommand() *cobra.Command {
	var settlementID, reference string
	cmd := &cobra.Command{
		Use:   "settle-external",
		Short: "Record the external receivables system's settlement reference exactly once",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			settlement, err := a.Client.RecordExternalSettlement(cmd.Context(), a.CorrelationID, client.RecordExternalSettlementInput{
				TeamID:            team,
				SettlementID:      settlementID,
				ExternalReference: reference,
			})
			if err != nil {
				return err
			}
			return a.emit(settlement, func(w io.Writer) {
				fmt.Fprintln(w, "settlement reconciled")
				kv(w, [][2]string{
					{"id", settlement.ID},
					{"invoice intent", settlement.InvoiceIntentID},
					{"amount", fmt.Sprintf("%d %s (minor units)", settlement.AmountMinor, settlement.Currency)},
					{"reference", reference},
				})
			})
		},
	}
	cmd.Flags().StringVar(&settlementID, "settlement-id", "", "settlement UUID (required)")
	cmd.Flags().StringVar(&reference, "reference", "", "external settlement reference (required)")
	_ = cmd.MarkFlagRequired("settlement-id")
	_ = cmd.MarkFlagRequired("reference")
	return cmd
}
