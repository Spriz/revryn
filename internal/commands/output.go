package commands

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"text/tabwriter"

	"github.com/revryn/billing-core/internal/client"
)

// SchemaVersion identifies the stable JSON envelope contract
// (contracts/cli/schemas/envelope.schema.json).
const SchemaVersion = "billingctl.v1"

// Envelope is the stable --json success envelope.
type Envelope struct {
	Data          any    `json:"data"`
	CorrelationID string `json:"correlationId"`
	Schema        string `json:"schema"`
}

// ErrorBody is the structured error payload written to stderr.
type ErrorBody struct {
	Kind     string                `json:"kind"`
	Code     string                `json:"code,omitempty"`
	Message  string                `json:"message"`
	Fields   []client.FieldProblem `json:"fields,omitempty"`
	ExitCode int                   `json:"exitCode"`
}

// ErrorEnvelope is the stable --json error envelope (stderr).
type ErrorEnvelope struct {
	Error         ErrorBody `json:"error"`
	CorrelationID string    `json:"correlationId,omitempty"`
	Schema        string    `json:"schema"`
}

// emit writes data as the versioned JSON envelope when --json is set,
// otherwise renders the human view.
func (a *App) emit(data any, human func(w io.Writer)) error {
	if a.JSON {
		return writeJSON(a.Stdout, Envelope{Data: data, CorrelationID: a.CorrelationID, Schema: SchemaVersion})
	}
	human(a.Stdout)
	return nil
}

// printError writes a structured error to stderr; the correlation ID is
// always printed on failures (SPEC §22.10).
func (a *App) printError(err error, code int) {
	var problem *client.ProblemError
	body := ErrorBody{
		Kind:     errorKind(err, code),
		Message:  err.Error(),
		ExitCode: code,
	}
	if errors.As(err, &problem) {
		body.Code = problem.Code
		body.Fields = problem.Fields
	}
	if a.JSON {
		_ = writeJSON(a.Stderr, ErrorEnvelope{Error: body, CorrelationID: a.CorrelationID, Schema: SchemaVersion})
		return
	}
	fmt.Fprintf(a.Stderr, "billingctl: error: %s\n", body.Message)
	for _, f := range body.Fields {
		fmt.Fprintf(a.Stderr, "  field %s: %s (%s)\n", joinPath(f.Path), f.Message, f.Code)
	}
	if a.CorrelationID != "" {
		fmt.Fprintf(a.Stderr, "correlation-id: %s\n", a.CorrelationID)
	}
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	return enc.Encode(v)
}

func joinPath(path []string) string {
	if len(path) == 0 {
		return "(input)"
	}
	out := path[0]
	for _, p := range path[1:] {
		out += "." + p
	}
	return out
}

// table renders an aligned text table for human output.
func table(w io.Writer, headers []string, rows [][]string) {
	tw := tabwriter.NewWriter(w, 2, 4, 2, ' ', 0)
	printRow(tw, headers)
	for _, row := range rows {
		printRow(tw, row)
	}
	tw.Flush()
}

func printRow(w io.Writer, cells []string) {
	for i, c := range cells {
		if i > 0 {
			fmt.Fprint(w, "\t")
		}
		fmt.Fprint(w, c)
	}
	fmt.Fprintln(w)
}

// kv renders aligned key/value detail output.
func kv(w io.Writer, pairs [][2]string) {
	tw := tabwriter.NewWriter(w, 2, 4, 2, ' ', 0)
	for _, p := range pairs {
		fmt.Fprintf(tw, "%s:\t%s\n", p[0], p[1])
	}
	tw.Flush()
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
