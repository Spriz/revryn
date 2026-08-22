# Security review — staged changes, 2026-08-22

Scope: the staged working set on `main` (demo journey orchestration, close
product surfaces across LiveView/GraphQL/CLI/MCP, close corrections
(ADR-031), unused-service credit funding, audit export, retention
governance, CI/release/image hardening). Method: manual review of every new
authorization boundary, input path, and secret-handling site in the diff,
with targeted code reading of the shared kernels they call. This is an
engineering self-review producing evidence for BC-TASK-073; it does not
replace the independent security review the release gate requires.

## Findings

No exploitable issue was found in the staged changes. Verified properties:

- **Authorization at every new boundary.** Each new GraphQL query/mutation
  runs `RequireScope` plus domain-level role checks; every new domain read
  API (`CloseWorkflow.list_*`, `posting_status`, `list_corrections`,
  `AuditExport.for_invoice_chain`, `Credits` listings) filters by
  `Scope.team_id!` and role set. Cross-team denial is covered by tests in
  browser, GraphQL, and domain layers. The corrected-policy lookup for
  close replacements is team-scoped (`policy_for_close!`), so a foreign
  team's policy id cannot be injected through the replacement form or API.
- **No atom-table or injection vectors.** All user-supplied identifiers go
  through `Ecto.UUID.cast`; evidence types and close states resolve against
  fixed lists (never `String.to_atom/1`); all queries are parameterized
  Ecto; the report download builds filenames only from a UUID slice and a
  whitelisted atom, and `send_download` forces attachment disposition.
- **Secrets stay out of evidence.** The audit export excludes connection
  rows entirely; a test asserts the connection's secret reference appears
  nowhere in any export byte. The e-conomic client already scrubs
  exception terms that could embed credential headers, so sync
  `last_error`/metadata (exported) cannot carry tokens. `doctor` prints
  redacted checks only.
- **Demo chaos affordance is contained.** `simulate_provider_failure/1`
  authorizes through `workspace_for_scope` (demo teams only), touches only
  the fake provider's injection API, and records an audit fact; it cannot
  reach a real adapter or any domain command.
- **Retention pruning is allowlist-bound.** `Retention.enforce/0` can only
  delete from four named operational tables; financial tables are
  structurally unreachable and the classification completeness test blocks
  unclassified new tables.
- **Release/ops knobs fail closed.** `PHX_CHECK_ORIGIN` unset keeps the
  framework default; the entrypoint's bundled `DATABASE_URL` default
  activates only when the bundled cluster exists, so web/worker roles still
  fail loudly on missing configuration.

## Accepted risks / follow-ups

1. `auditExport` and `creditClose.report` return whole evidence files
   base64-inline. Complexity analysis bounds query shape, not byte size;
   acceptable at current evidence sizes and auditor-gated access. Follow-up
   if evidence grows: size caps or an authenticated download URL.
2. The CI workflows use a fixed, clearly-labeled `SECRET_KEY_BASE` for
   ephemeral throwaway databases. Not a secret; documented here so nobody
   mistakes it for one.
3. `PHX_CHECK_ORIGIN=false` exists for isolated lab environments; the
   runbook warns against production use. No enforcement beyond
   documentation.
4. GraphQL has complexity limits but no per-principal rate limiting;
   pre-existing, tracked under the capacity review (BC-TASK-077).
5. This review covers the staged diff, not the whole system. The
   independent whole-system security review demanded by the release gate
   (BC-TASK-073) remains open and cannot be self-performed.
