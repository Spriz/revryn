package commands

import (
	"errors"
	"fmt"
	"strings"

	"github.com/revryn/billing-core/internal/client"
)

// Registered exit codes. The registry lives in contracts/cli/exit-codes.md;
// codes are stable compatibility surface and are never reused (SPEC §14.14).
const (
	ExitOK         = 0 // success
	ExitGeneric    = 1 // unclassified failure
	ExitUsage      = 2 // CLI usage error (flags, arguments, local validation)
	ExitAuth       = 3 // authentication / explicit authorization failure
	ExitNotFound   = 4 // not found or unauthorized (indistinguishable by design)
	ExitValidation = 5 // domain validation / mapping precondition problem
	ExitConflict   = 6 // version or idempotency conflict
	ExitTransport  = 7 // server/transport failure (5xx, network, malformed)
)

// UsageError marks command-line usage problems (exit code 2).
type UsageError struct{ Err error }

func (e *UsageError) Error() string { return e.Err.Error() }
func (e *UsageError) Unwrap() error { return e.Err }

// ExitCode maps an error to its registered exit code.
func ExitCode(err error) int {
	if err == nil {
		return ExitOK
	}
	var usage *UsageError
	if errors.As(err, &usage) {
		return ExitUsage
	}
	var auth *client.AuthError
	if errors.As(err, &auth) {
		return ExitAuth
	}
	var notFound *client.NotFoundError
	if errors.As(err, &notFound) {
		return ExitNotFound
	}
	var problem *client.ProblemError
	if errors.As(err, &problem) {
		switch problem.Kind {
		case client.ProblemValidation, client.ProblemMapping:
			return ExitValidation
		case client.ProblemAuthorization:
			return ExitAuth
		case client.ProblemVersionConflict, client.ProblemIdempotencyConflict:
			return ExitConflict
		}
		return ExitGeneric
	}
	var transport *client.TransportError
	if errors.As(err, &transport) {
		return ExitTransport
	}
	var httpErr *client.HTTPError
	if errors.As(err, &httpErr) {
		if httpErr.StatusCode >= 500 {
			return ExitTransport
		}
		return ExitGeneric
	}
	if isCobraUsageError(err) {
		return ExitUsage
	}
	return ExitGeneric
}

// errorKind returns the stable machine-readable classification used in the
// JSON error envelope.
func errorKind(err error, code int) string {
	var problem *client.ProblemError
	if errors.As(err, &problem) {
		return string(problem.Kind)
	}
	switch code {
	case ExitUsage:
		return "usage"
	case ExitAuth:
		return "auth"
	case ExitNotFound:
		return "not_found"
	case ExitTransport:
		return "transport"
	default:
		var gql *client.GraphQLError
		if errors.As(err, &gql) {
			return "graphql"
		}
		return "generic"
	}
}

// isCobraUsageError detects usage errors cobra reports as plain errors
// (unknown command, bad argument count, missing required flags).
func isCobraUsageError(err error) bool {
	msg := err.Error()
	for _, marker := range []string{
		"unknown command",
		"unknown flag",
		"unknown shorthand flag",
		"required flag",
		"accepts ",
		"requires at least",
		"invalid argument",
	} {
		if strings.Contains(msg, marker) {
			return true
		}
	}
	return false
}

// validateDate enforces the ISO 8601 calendar date shape (YYYY-MM-DD)
// client-side so malformed flag values fail fast as usage errors.
func validateDate(flag, value string) error {
	if len(value) == 10 && value[4] == '-' && value[7] == '-' && allDigits(value[:4]) && allDigits(value[5:7]) && allDigits(value[8:]) {
		return nil
	}
	return &UsageError{Err: fmt.Errorf("--%s must be an ISO 8601 date (YYYY-MM-DD), got %q", flag, value)}
}

func allDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
