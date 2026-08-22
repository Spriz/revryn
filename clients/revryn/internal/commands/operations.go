package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

func (a *App) newOperationsCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "operations",
		Short: "Follow and retry durable operations",
	}

	get := &cobra.Command{
		Use:   "get <id>",
		Short: "Show a durable operation",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			op, err := a.Client.Operation(cmd.Context(), a.CorrelationID, team, args[0])
			if err != nil {
				return err
			}
			return a.emit(op, func(w io.Writer) { printOperation(w, op) })
		},
	}

	retry := &cobra.Command{
		Use:   "retry <id>",
		Short: "Manually retry a failed durable operation (retryOperation)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			team, err := a.requireTeam()
			if err != nil {
				return err
			}
			op, err := a.Client.RetryOperation(cmd.Context(), a.CorrelationID, client.RetryOperationInput{
				TeamID:      team,
				OperationID: args[0],
			})
			if err != nil {
				return err
			}
			return a.emit(op, func(w io.Writer) {
				fmt.Fprintln(w, "retry requested")
				printOperation(w, op)
			})
		},
	}

	cmd.AddCommand(get, retry)
	return cmd
}
