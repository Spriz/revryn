package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"
)

func (a *App) newCustomersCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "customers",
		Short: "Inspect team customers",
	}

	var first int
	var after string
	list := &cobra.Command{
		Use:   "list",
		Short: "List customers (bounded cursor connection)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			conn, err := a.Client.Customers(cmd.Context(), a.CorrelationID, team, first, after)
			if err != nil {
				return err
			}
			return a.emit(conn, func(w io.Writer) {
				rows := make([][]string, 0, len(conn.Edges))
				for _, e := range conn.Edges {
					rows = append(rows, []string{e.Node.ID, e.Node.ExternalID, dash(e.Node.LegalName), e.Node.Status, fmt.Sprint(e.Node.CurrentVersion)})
				}
				table(w, []string{"ID", "EXTERNAL ID", "LEGAL NAME", "STATUS", "VERSION"}, rows)
				if conn.PageInfo.HasNextPage {
					fmt.Fprintf(w, "\nmore results available; continue with --after %s\n", conn.PageInfo.EndCursor)
				}
			})
		},
	}
	list.Flags().IntVar(&first, "first", 50, "maximum customers to return")
	list.Flags().StringVar(&after, "after", "", "opaque cursor from a previous page")

	get := &cobra.Command{
		Use:   "get <id>",
		Short: "Show one customer",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			customer, err := a.Client.Customer(cmd.Context(), a.CorrelationID, team, args[0])
			if err != nil {
				return err
			}
			return a.emit(customer, func(w io.Writer) {
				kv(w, [][2]string{
					{"id", customer.ID},
					{"external id", customer.ExternalID},
					{"legal name", dash(customer.LegalName)},
					{"status", customer.Status},
					{"current version", fmt.Sprint(customer.CurrentVersion)},
				})
			})
		},
	}

	cmd.AddCommand(list, get)
	return cmd
}
