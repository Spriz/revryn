# Billing Core MCP tool contract

`billingctl mcp serve` exposes Billing Core to agentic consumers over the
Model Context Protocol (SPEC §12.2.3, BC-US-158, INV-044, ADR-027), built on
the official Go SDK `github.com/modelcontextprotocol/go-sdk`.

Tool names, input/output JSON Schemas, annotations, and side-effect
descriptions are reviewed compatibility artifacts (SPEC §14.14): removal or
incompatible narrowing requires a deprecation/migration policy. Schemas are
derived from the typed Go structs in `internal/mcp/tools_read.go` and
`internal/mcp/tools_mutate.go` and validated by the SDK on every call.

## Transport, auth, scope

- **Transport:** stdio (`billingctl mcp serve`). Streamable HTTP for remote
  deployment is planned but not yet wired in this codebase.
- **Auth:** the bearer token resolved at serve start (`--token` /
  `BILLING_TOKEN`) is used for every upstream GraphQL call. The MCP server
  holds no privileged access — it is subject to exactly the authorization the
  token grants (INV-045).
- **Team scope:** `--team` / `BILLING_TEAM` at serve start sets the default
  team. Every team-scoped tool also accepts an optional `team_id` input that
  overrides the default; calls without any team scope fail with
  `team scope required`.
- **Safety:** no arbitrary GraphQL, SQL, or shell execution is exposed
  (ADR-027). Tool errors carry safe messages plus a correlation reference;
  upstream HTTP bodies are never forwarded.
- **Correlation:** every tool call generates a correlation UUID, sends it as
  `X-Correlation-Id` upstream, and returns it as `correlationId` in the
  output (SPEC §22.10).
- **Pagination:** list tools are bounded — `first` defaults to 20 and is
  clamped to 100.

## Read-only tools

All carry `readOnlyHint: true` and perform no writes anywhere.

| Tool | Inputs | Output (structured) | Upstream |
|------|--------|---------------------|----------|
| `billing_status` | — | `apiVersion`, `viewer` (memberships), `correlationId` | `apiVersion`, `viewer` |
| `list_customers` | `team_id?`, `first?`, `after?` | `customers[]`, `hasNextPage`, `endCursor`, `correlationId` | `customers` |
| `get_customer` | `team_id?`, `customer_id` | `customer`, `correlationId` | `customer` |
| `list_subscriptions` | `team_id?`, `first?`, `after?` | `subscriptions[]`, `hasNextPage`, `endCursor`, `correlationId` | `subscriptions` |
| `get_subscription` | `team_id?`, `subscription_id` | `subscription`, `correlationId` | `subscription` |
| `preview_invoice` | `team_id?`, `subscription_id`, `as_of` (YYYY-MM-DD) | `preview` (lines, net amount, freeze `blockers`), `correlationId` | `invoicePreview` |
| `get_invoice` | `team_id?`, `invoice_intent_id` | `invoiceIntent` (state + lines), `correlationId` | `invoiceIntent` |
| `get_operation` | `team_id?`, `operation_id` | `operation` (state, attempts, safe error), `correlationId` | `operation` |

## Mutating tools

All carry `readOnlyHint: false`, `destructiveHint: false` (Billing Core
mutations are additive, append-only financial records), and
`idempotentHint: false` (omitting `idempotency_key` generates a fresh key per
call; passing an explicit key makes retries safe).

**Confirmation:** every mutating tool has a required boolean `confirm` input.
Calls without `confirm` fail schema validation; calls with `confirm: false`
are rejected before any upstream request. Consequential financial actions are
never executed on model intent alone (SPEC §14.14).

**Idempotency:** where the upstream GraphQL input defines `idempotencyKey`,
the tool accepts an optional `idempotency_key` and auto-generates a UUID
otherwise; the effective key is echoed in the output so agents can retry
safely. `approve_invoice` and `retry_operation` define no upstream
idempotency key (schema artifact), so those tools carry none.

| Tool | Inputs (besides `confirm`, `team_id?`) | Output (structured) | Upstream |
|------|-----------------------------------------|---------------------|----------|
| `freeze_invoice` | `subscription_id`, `as_of`, `billing_run_id?`, `idempotency_key?` | `invoiceIntent`, `idempotencyKey`, `correlationId` | `freezeInvoiceIntent` |
| `synchronize_invoice` | `invoice_intent_id`, `idempotency_key?` | `operation` (follow with `get_operation`), `idempotencyKey`, `correlationId` | `synchronizeInvoice` |
| `approve_invoice` | `invoice_intent_id`, `reason?` | `invoiceIntent`, `correlationId` | `approveInvoice` |
| `book_invoice` | `invoice_intent_id`, `idempotency_key?` | `operation` (follow with `get_operation`), `idempotencyKey`, `correlationId` | `bookInvoice` |
| `retry_operation` | `operation_id` | `operation`, `correlationId` | `retryOperation` |
| `create_billing_run` | `invoice_date`, `run_key?` (default `run-<invoice_date>`), `usage_cutoff?` (default `<invoice_date>T00:00:00Z`), `idempotency_key?` | `billingRun`, `idempotencyKey`, `correlationId` | `createBillingRun` |

## Error mapping

Client errors map to MCP tool errors (`isError: true`) with safe messages:

| Upstream condition | Tool error message shape |
|--------------------|--------------------------|
| Typed problem result (`ValidationProblem`, `MappingProblem`, `AuthorizationProblem`, `VersionConflict`, `IdempotencyConflict`) | `<kind> problem (<code>): <server message>` — server problem messages are part of the public contract and safe to show. |
| HTTP 401/403 or unauthenticated GraphQL error | `authentication or authorization failed against Billing Core` |
| Null team-scoped lookup | `<resource> "<id>" not found or not accessible` (not-found and unauthorized are indistinguishable by design). |
| Network/5xx after retries | `Billing Core unreachable (N attempts)` |
| Other non-200 | `Billing Core returned HTTP <code>` |

Every tool error ends with `[correlation-id: <uuid>]` for audit/log lookup.

## Conformance tests

`internal/mcp/server_test.go` exercises tool listing and annotations,
required-`confirm` schemas, a read tool, confirm gating for a mutating tool
(including that no upstream call happens without confirmation), team-scope
validation, and safe error mapping — all over the SDK's in-memory transport.
