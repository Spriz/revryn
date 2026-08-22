package commands

import (
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"
)

func (a *App) newStatusCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show API version and the authenticated viewer's memberships",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			status, err := a.Client.Status(cmd.Context(), a.CorrelationID)
			if err != nil {
				return err
			}
			return a.emit(status, func(w io.Writer) {
				kv(w, [][2]string{
					{"api version", status.APIVersion},
					{"url", a.URL},
				})
				if status.Viewer == nil {
					fmt.Fprintln(w, "viewer:       (not authenticated; pass --token or set BILLING_TOKEN)")
					return
				}
				v := status.Viewer
				kv(w, [][2]string{
					{"viewer", v.ID},
					{"status", v.Status},
					{"platform admin", fmt.Sprint(v.PlatformAdmin)},
				})
				if len(v.TeamMemberships) > 0 {
					fmt.Fprintln(w, "\nteam memberships:")
					rows := make([][]string, 0, len(v.TeamMemberships))
					for _, m := range v.TeamMemberships {
						rows = append(rows, []string{m.Team.ID, m.Team.Name, m.Team.BaseCurrency, strings.Join(m.Roles, ",")})
					}
					table(w, []string{"TEAM ID", "NAME", "CURRENCY", "ROLES"}, rows)
				}
				if len(v.OrganizationMemberships) > 0 {
					fmt.Fprintln(w, "\norganization memberships:")
					rows := make([][]string, 0, len(v.OrganizationMemberships))
					for _, m := range v.OrganizationMemberships {
						rows = append(rows, []string{m.Organization.ID, m.Organization.Name, strings.Join(m.Roles, ",")})
					}
					table(w, []string{"ORG ID", "NAME", "ROLES"}, rows)
				}
			})
		},
	}
}
