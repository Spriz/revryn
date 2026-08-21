# billingctl — CLI contract

`billingctl` is the official Go CLI for Billing Core (SPEC §12.2.3,
BC-US-157, INV-043). It is a client of the public GraphQL contract in
`schema/billing_core.graphql`; it never connects to PostgreSQL or bypasses
domain authorization.

## Build

```sh
CGO_ENABLED=0 go build -o billingctl ./cmd/billingctl
```

The binary is fully static (no cgo). Cross-compile with the usual
`GOOS`/`GOARCH` matrix, e.g. `GOOS=linux GOARCH=arm64`. Stamp a release
version with:

```sh
CGO_ENABLED=0 go build \
  -ldflags "-X github.com/revryn/billing-core/internal/commands.Version=1.2.3" \
  -o billingctl ./cmd/billingctl
```

`make -f Makefile.billingctl build` wraps the above; `test`, `vet`, and
`lint` targets are also provided.

## Global flags

| Flag | Env | Default | Meaning |
|------|-----|---------|---------|
| `--url` | `BILLING_URL` | `http://localhost:4000` | Server base URL (the `/graphql` path is appended). |
| `--token` | `BILLING_TOKEN` | — | Bearer session token. |
| `--team` | `BILLING_TEAM` | — | Team UUID scope for team-scoped commands. |
| `--correlation-id` | — | generated UUID | Sent as `X-Correlation-Id`, printed on failures, included in JSON output (SPEC §22.10). |
| `--json` | — | off | Emit the stable `billingctl.v1` envelope instead of human tables. |

## Commands

| Command | GraphQL operation | Notes |
|---------|-------------------|-------|
| `status` | `apiVersion`, `viewer` | Memberships summary. |
| `doctor` | `apiVersion` (anonymous) + `viewer` (with token) | Connectivity and auth diagnosis. |
| `customers list [--first N] [--after CUR]` | `customers` | Bounded cursor connection. |
| `customers get <id>` | `customer` | |
| `subscriptions list [--first N] [--after CUR]` | `subscriptions` | |
| `subscriptions get <id>` | `subscription` | |
| `subscriptions create --contract --plan-version --external-id --start --quantity [--end] [--anchor-day] [--idempotency-key]` | `createSubscription` | Idempotency key auto-generated (UUID) when absent. |
| `invoices preview --subscription <id> --as-of <date>` | `invoicePreview` | Renders lines plus freeze blockers. |
| `invoices freeze --subscription <id> --as-of <date> [--billing-run] [--idempotency-key]` | `freezeInvoiceIntent` | |
| `invoices get <intent-id>` | `invoiceIntent` | Includes lifecycle state and lines. |
| `invoices sync <intent-id> [--idempotency-key]` | `synchronizeInvoice` | Prints the durable operation ID + state. |
| `invoices approve <intent-id> [--reason]` | `approveInvoice` | |
| `invoices book <intent-id> [--idempotency-key]` | `bookInvoice` | Prints the durable operation ID + state. |
| `operations get <id>` | `operation` | |
| `operations retry <id>` | `retryOperation` | |
| `runs create --date <d> [--run-key] [--usage-cutoff] [--idempotency-key]` | `createBillingRun` | `run-key` defaults to `run-<date>`, `usage-cutoff` to `<date>T00:00:00Z`. |
| `runs get <id>` | `billingRun` | |
| `mcp serve` | — | Serves the MCP tool set over stdio (see `contracts/mcp/tools.md`). |

All mutations send a `clientMutationId` equal to the correlation ID, and every
mutation whose input defines `idempotencyKey` auto-generates a UUID unless
`--idempotency-key` is passed.

## JSON output

Success envelopes (stdout):

```json
{"data": {...}, "correlationId": "uuid", "schema": "billingctl.v1"}
```

Error envelopes (stderr) and exit codes: see `exit-codes.md`. The formal
schema is `schemas/envelope.schema.json`; the byte-exact examples under
`golden/` are compatibility-checked by `internal/commands/commands_test.go`
(regenerate deliberately with `UPDATE_GOLDEN=1 go test ./internal/commands/`).

## Retry and correlation semantics

The shared client (`internal/client`) retries network failures and 5xx
responses up to 4 attempts with exponential backoff and equal jitter
(base 250ms, cap 5s). 4xx responses, GraphQL errors, and typed problem
results are never retried. Every request carries `X-Correlation-Id`.

## Testing

`go test ./...` runs deterministic unit tests against `httptest` stubs.
One live smoke test (`TestLiveSmoke` in `internal/client`) runs only when
`BILLING_URL` is set:

```sh
BILLING_URL=http://localhost:4000 go test ./internal/client/ -run TestLiveSmoke -v
```
