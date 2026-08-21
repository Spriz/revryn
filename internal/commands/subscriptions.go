package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/revryn/billing-core/internal/client"
)

func (a *App) newSubscriptionsCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "subscriptions",
		Short: "Inspect and start subscriptions",
	}

	var first int
	var after string
	list := &cobra.Command{
		Use:   "list",
		Short: "List subscriptions (bounded cursor connection)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			conn, err := a.Client.Subscriptions(cmd.Context(), a.CorrelationID, team, first, after)
			if err != nil {
				return err
			}
			return a.emit(conn, func(w io.Writer) {
				rows := make([][]string, 0, len(conn.Edges))
				for _, e := range conn.Edges {
					rows = append(rows, []string{e.Node.ID, e.Node.ExternalID, e.Node.State, e.Node.StartsOn, dash(e.Node.EndDateExclusive), fmt.Sprint(e.Node.CurrentVersion)})
				}
				table(w, []string{"ID", "EXTERNAL ID", "STATE", "STARTS ON", "ENDS (EXCL)", "VERSION"}, rows)
				if conn.PageInfo.HasNextPage {
					fmt.Fprintf(w, "\nmore results available; continue with --after %s\n", conn.PageInfo.EndCursor)
				}
			})
		},
	}
	list.Flags().IntVar(&first, "first", 50, "maximum subscriptions to return")
	list.Flags().StringVar(&after, "after", "", "opaque cursor from a previous page")

	get := &cobra.Command{
		Use:   "get <id>",
		Short: "Show one subscription",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			sub, err := a.Client.Subscription(cmd.Context(), a.CorrelationID, team, args[0])
			if err != nil {
				return err
			}
			return a.emit(sub, func(w io.Writer) { printSubscription(w, sub) })
		},
	}

	var (
		contractID     string
		planVersionID  string
		externalID     string
		start          string
		quantity       string
		endDate        string
		anchorDay      int
		idempotencyKey string
	)
	create := &cobra.Command{
		Use:   "create",
		Short: "Start a subscription (createSubscription)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			if err := validateDate("start", start); err != nil {
				return err
			}
			if endDate != "" {
				if err := validateDate("end", endDate); err != nil {
					return err
				}
			}
			input := client.CreateSubscriptionInput{
				TeamID:           team,
				ContractID:       contractID,
				PlanVersionID:    planVersionID,
				ExternalID:       externalID,
				StartsOn:         start,
				EndDateExclusive: endDate,
				BillingAnchorDay: anchorDay,
				Quantity:         quantity,
				IdempotencyKey:   idempotencyKey,
			}
			sub, err := a.Client.CreateSubscription(cmd.Context(), a.CorrelationID, input)
			if err != nil {
				return err
			}
			return a.emit(sub, func(w io.Writer) {
				fmt.Fprintln(w, "subscription created")
				printSubscription(w, sub)
			})
		},
	}
	cf := create.Flags()
	cf.StringVar(&contractID, "contract", "", "contract UUID (required)")
	cf.StringVar(&planVersionID, "plan-version", "", "published plan version UUID (required)")
	cf.StringVar(&externalID, "external-id", "", "caller-stable external subscription ID (required)")
	cf.StringVar(&start, "start", "", "start date YYYY-MM-DD (required)")
	cf.StringVar(&quantity, "quantity", "", "decimal quantity, e.g. 3 or 2.5 (required)")
	cf.StringVar(&endDate, "end", "", "exclusive end date YYYY-MM-DD")
	cf.IntVar(&anchorDay, "anchor-day", 0, "billing anchor day of month")
	cf.StringVar(&idempotencyKey, "idempotency-key", "", "idempotency key (generated UUID when absent)")
	for _, name := range []string{"contract", "plan-version", "external-id", "start", "quantity"} {
		_ = create.MarkFlagRequired(name)
	}

	cmd.AddCommand(list, get, create)
	return cmd
}

func printSubscription(w io.Writer, s *client.Subscription) {
	kv(w, [][2]string{
		{"id", s.ID},
		{"external id", s.ExternalID},
		{"contract", s.ContractID},
		{"state", s.State},
		{"starts on", s.StartsOn},
		{"ends (excl)", dash(s.EndDateExclusive)},
		{"anchor day", zeroDash(s.BillingAnchorDay)},
		{"time zone", s.TimeZone},
		{"version", fmt.Sprint(s.Version)},
		{"current version", fmt.Sprint(s.CurrentVersion)},
	})
}

func zeroDash(n int) string {
	if n == 0 {
		return "-"
	}
	return fmt.Sprint(n)
}
