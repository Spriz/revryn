package client

import (
	"fmt"
	"strings"
)

// ProblemKind classifies typed GraphQL problem results (schema unions).
type ProblemKind string

const (
	ProblemValidation          ProblemKind = "validation"
	ProblemMapping             ProblemKind = "mapping"
	ProblemAuthorization       ProblemKind = "authorization"
	ProblemVersionConflict     ProblemKind = "version_conflict"
	ProblemIdempotencyConflict ProblemKind = "idempotency_conflict"
)

// FieldProblem mirrors the GraphQL FieldProblem type.
type FieldProblem struct {
	Path    []string `json:"path"`
	Code    string   `json:"code"`
	Message string   `json:"message"`
}

// ProblemError is a typed problem result returned inside a mutation union
// (ValidationProblem, MappingProblem, AuthorizationProblem, VersionConflict,
// IdempotencyConflict). Its messages come from the server and are safe to
// show to users.
type ProblemError struct {
	Typename        string
	Kind            ProblemKind
	Code            string
	Message         string
	Fields          []FieldProblem
	ExpectedVersion *int
	ActualVersion   *int
}

func (e *ProblemError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s problem", e.Kind)
	if e.Code != "" {
		fmt.Fprintf(&b, " (%s)", e.Code)
	}
	if e.Message != "" {
		fmt.Fprintf(&b, ": %s", e.Message)
	}
	if e.Kind == ProblemVersionConflict {
		fmt.Fprintf(&b, ": expected version %s, actual version %s", intOrDash(e.ExpectedVersion), intOrDash(e.ActualVersion))
	}
	return b.String()
}

func intOrDash(v *int) string {
	if v == nil {
		return "-"
	}
	return fmt.Sprint(*v)
}

// AuthError indicates the caller could not be authenticated (HTTP 401/403 or
// an unauthenticated/unauthorized top-level GraphQL error).
type AuthError struct {
	StatusCode    int
	Message       string
	CorrelationID string
}

func (e *AuthError) Error() string {
	if e.Message != "" {
		return e.Message
	}
	return fmt.Sprintf("authentication failed (HTTP %d)", e.StatusCode)
}

// NotFoundError indicates a nullable query field came back null. Billing Core
// deliberately does not distinguish "does not exist" from "not authorized"
// for team-scoped lookups, so neither can this error (exit code 4).
type NotFoundError struct {
	Resource string
	ID       string
}

func (e *NotFoundError) Error() string {
	if e.ID == "" {
		return fmt.Sprintf("%s not found or not accessible", e.Resource)
	}
	return fmt.Sprintf("%s %q not found or not accessible", e.Resource, e.ID)
}

// GraphQLError carries top-level (non-domain) GraphQL errors.
type GraphQLError struct {
	Errors        []GQLErrorItem
	CorrelationID string
}

func (e *GraphQLError) Error() string {
	if len(e.Errors) == 0 {
		return "graphql error"
	}
	msgs := make([]string, 0, len(e.Errors))
	for _, item := range e.Errors {
		msgs = append(msgs, item.Message)
	}
	return "graphql: " + strings.Join(msgs, "; ")
}

// HTTPError is a non-200 HTTP response that is not an auth failure. 5xx
// responses only surface as HTTPError wrapped in TransportError after
// retries are exhausted.
type HTTPError struct {
	StatusCode    int
	Body          string
	CorrelationID string
}

func (e *HTTPError) Error() string {
	return fmt.Sprintf("server returned HTTP %d", e.StatusCode)
}

// TransportError indicates the request could not be completed after all
// retry attempts (network failures and/or 5xx responses).
type TransportError struct {
	Err           error
	Attempts      int
	CorrelationID string
}

func (e *TransportError) Error() string {
	return fmt.Sprintf("request failed after %d attempts: %v", e.Attempts, e.Err)
}

func (e *TransportError) Unwrap() error { return e.Err }
