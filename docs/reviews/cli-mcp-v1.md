# CLI/MCP certification v1 (BC-TASK-100)

Date: 2026-08-22. Verdict: **certified for the covered scope** — the
representative workflows below run end-to-end against a live server with
real authentication; release-artifact signing/SBOM distribution remains
open (see gaps).

## Reproduce

```sh
mix phx.server &            # or any running deployment
BASE_URL=http://localhost:4000 e2e/cli/run.sh
BASE_URL=http://localhost:4000 e2e/mcp/run.sh
```

The fixture (`e2e/cli/fixture.exs`) creates a real user, workspace,
customer, and funded credit account through domain commands and mints a
bearer session; CI runs it through `bin/billing_core eval` against the
booted production release.

## CLI evidence (`e2e/cli/run.sh`)

- `status` resolves the authenticated principal and team membership
  (real session token, `--json` envelope with schema + correlation id).
- `customers list` and `credits accounts` read team-scoped data — the
  granted 125.00 DKK balance round-trips exactly (integer minor units).
- `credit-closes create-policy` executes an accounting-sensitive mutation
  with explicit accountant-approved inputs, including the §9.4.1
  settlement mode; `policies` reflects the created version.
- Failure handling: an invalid token exits non-zero with a stable auth
  error; unknown/cross-team ids answer not-found without leaking; every
  error path prints the correlation reference (SPEC §22.10).
- The full command matrix (invoices preview/freeze/sync/approve/book,
  runs, operations retry, close generate→approve→post→accept→report,
  reverse/replace, credits grant/settle) is exercised continuously by the
  golden/unit suites in `internal/commands` against a stubbed server, and
  the shared client layer is what this live run certifies.

## MCP evidence (`e2e/mcp/run.sh`)

- Real stdio JSON-RPC handshake with the `billing-core` implementation.
- Tool discovery: 30+ tools; every read carries `readOnlyHint: true`,
  mutations do not; input/output schemas present (asserted continuously in
  `internal/mcp/server_test.go`).
- `billing_status` executes with real upstream auth and returns structured
  content with a correlation id.
- Agent safety: `grant_credit` with `confirm: false` is refused before any
  upstream request ("confirmation required…"), matching INV-044/§14.14 —
  consequential financial actions never execute on model intent alone.

## Consistency

`contracts/mcp/tools.md` and the server's registered tool set are kept
identical by `server_test.go`'s canonical tool lists; CLI `--help`,
goldens, and `docs/cli/*.md` are exercised by the commands test suite.
The GraphQL documents the client sends are string-built from the SDL
artifact that CI diffs.

## Release distribution

`.github/workflows/release-revryn.yml` builds the full BC-US-157
matrix (linux amd64/arm64, macOS amd64/arm64, windows amd64; CGO off,
trimmed, version-stamped), emits `SHA256SUMS`, an SPDX SBOM, and signs
both **keyless via Sigstore/GitHub OIDC** — no long-lived signing secret
required; `VERIFY.md` ships alongside with the cosign verification
command. Tag `cli/vX.Y.Z` publishes to a GitHub release;
workflow_dispatch produces dry-run artifacts. The cross-compile matrix is
locally proven (all targets build and run `--help`).

## Remaining gap

1. MCP certification drives the two highest-risk paths live; extending
   the live matrix to the full close remediation loop is scripted work on
   the same harness.
