package commands

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/spriz/revryn/clients/revryn/internal/client"
)

type doctorConnectivity struct {
	OK         bool   `json:"ok"`
	APIVersion string `json:"apiVersion,omitempty"`
	Error      string `json:"error,omitempty"`
}

type doctorAuth struct {
	Checked  bool   `json:"checked"`
	OK       bool   `json:"ok"`
	ViewerID string `json:"viewerId,omitempty"`
	Status   string `json:"status,omitempty"`
	Error    string `json:"error,omitempty"`
}

type doctorReport struct {
	URL          string             `json:"url"`
	Connectivity doctorConnectivity `json:"connectivity"`
	Auth         doctorAuth         `json:"auth"`
}

func (a *App) newDoctorCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Check connectivity (apiVersion without token) and authentication (viewer with token)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			report := doctorReport{URL: a.URL}
			var failure error

			// Connectivity: anonymous apiVersion probe.
			anon := client.New(client.Config{BaseURL: a.URL, UserAgent: "revryn/" + Version})
			version, err := anon.APIVersion(cmd.Context(), a.CorrelationID)
			if err != nil {
				report.Connectivity.Error = err.Error()
				failure = err
			} else {
				report.Connectivity.OK = true
				report.Connectivity.APIVersion = version
			}

			// Auth: authenticated viewer probe (only when reachable and a token exists).
			if failure == nil && a.Token != "" {
				report.Auth.Checked = true
				status, err := a.Client.Status(cmd.Context(), a.CorrelationID)
				switch {
				case err != nil:
					report.Auth.Error = err.Error()
					failure = err
				case status.Viewer == nil:
					report.Auth.Error = "token accepted no viewer: session is invalid or expired"
					failure = &client.AuthError{Message: report.Auth.Error, CorrelationID: a.CorrelationID}
				default:
					report.Auth.OK = true
					report.Auth.ViewerID = status.Viewer.ID
					report.Auth.Status = status.Viewer.Status
				}
			}

			emitErr := a.emit(report, func(w io.Writer) {
				fmt.Fprintf(w, "url:           %s\n", report.URL)
				if report.Connectivity.OK {
					fmt.Fprintf(w, "connectivity:  ok (apiVersion %s)\n", report.Connectivity.APIVersion)
				} else {
					fmt.Fprintf(w, "connectivity:  FAILED (%s)\n", report.Connectivity.Error)
				}
				switch {
				case !report.Auth.Checked && a.Token == "":
					fmt.Fprintln(w, "auth:          skipped (no token; pass --token or set BILLING_TOKEN)")
				case !report.Auth.Checked:
					fmt.Fprintln(w, "auth:          skipped (server unreachable)")
				case report.Auth.OK:
					fmt.Fprintf(w, "auth:          ok (viewer %s, status %s)\n", report.Auth.ViewerID, report.Auth.Status)
				default:
					fmt.Fprintf(w, "auth:          FAILED (%s)\n", report.Auth.Error)
				}
			})
			if failure != nil {
				return failure
			}
			return emitErr
		},
	}
}
