---
id: erp-synchronization
title: ERP synchronization
status: supported
public: true
owners: [billing-domain]
graphql:
  - ErpConnection
  - Operation
  - erpConnection
  - operation
  - validateErpConnection
  - synchronizeInvoice
  - approveInvoice
  - bookInvoice
  - retryOperation
tests:
  integration:
    - test/workflows/invoice_sync_test.exs
    - test/workflows/external_booking_test.exs
    - test/workflows/annual_prepaid_subscription_test.exs
adrs:
  - SPEC.md Epic F, §17.4–17.15, §21.3, §22.9.1, INV-008…011
---

# ERP synchronization

## Purpose

Move frozen invoice intents into the ERP as drafts, verify every external
write by read-after-write reconciliation before any state claim
(INV-008/009), gate booking behind explicit approval, and recover safely
from unknown outcomes, human edits, and external booking.

## User outcomes

- A finance operator requests synchronization; mapping/validation blockers
  are reported up front with no side effects (BC-US-080).
- The created draft is read back and compared field by field; only a
  matching draft reaches `erp_draft`.
- Approval pins the external draft hash; any later human edit in the ERP is
  detected as hash drift and blocks booking with remediation (BC-US-084).
- A draft booked directly inside the ERP is detected by polling, reconciled
  against the frozen intent, and recorded as booked (BC-US-086).

## Actors and permissions

Connection management and all sync/approve/book/retry commands:
`finance_operator` (connection create/validate also `team_admin`). Workers
transition intents as `:system`.

## Domain terminology

- **Connection** — one per team; credentials live only in the secret store
  (`secret_reference`; default provider resolves an env var). Statuses:
  `unvalidated` / `active` / `action_required`.
- **Canonical invoice** — adapter-neutral document built from the frozen
  intent + validated mappings; the frozen customer version snapshot
  supplies the recipient (§17.4). External reference:
  `abc:<team-short>:<intent-id>:v<version>`.
- **Reconciliation severity** — `fatal` (customer, recipient fingerprint,
  currency, product, net line amount, missing/extra line, recognition mode,
  accrual dates … stops automation), `warning` (normalized-equivalent
  formatting), `informational` (provider VAT, invoice number, PDF link).
  Only fatal differences produce `mismatch`.

## Workflows

1. `ERP.create_connection` / `validate_connection` (BC-US-003/004) —
   adapter capabilities + preflight persisted as evidence; any failing
   check → `action_required`.
2. `Sync.request_synchronization` (BC-US-081) — builder validates customer
   mapping, recipient snapshot, and per-line product mappings (blockers
   block, INV-011); transitions the intent to `sync_pending`; creates the
   `erp_document`, a durable `erp.create_draft` operation (operation key
   `create_draft:<intent>:v<version>`, hashed idempotency key), and
   enqueues the Oban `SyncWorker` (queue `erp`).
3. Draft creation — `adapter.create_draft` with the idempotency key, then
   read-back compare. Match: document `draft`, intent `erp_draft`,
   operation `succeeded`, `erp_document.draft_created.v1`. Fatal mismatch:
   document `reconciliation_failed`, operation fails (`validation` class),
   intent `sync_error`, `erp_document.reconciliation_failed.v1`.
4. `Sync.approve_invoice` (BC-US-084) — requires a currently reconciled
   draft; records intent hash + external draft hash in an approval record.
5. `Sync.request_booking` (BC-US-085) — re-fetches the draft first; hash
   drift vs the approved snapshot blocks with
   `external_draft_changed_after_approval` (intent `sync_error`); otherwise
   books (delivery mode from team settings, default `:none`) and
   reconciles the booked document before claiming `erp_booked`.
6. Unknown outcome (BC-US-105) — `{:unknown, hint}` from the adapter moves
   the operation to `outcome_unknown` → `reconciling`; the document is
   looked up by external reference: found → reconcile and complete
   (`effect_found`); proven absent → `absence_proven` → retry queued. Never
   a blind retry.
7. Polling (§17.12) — `PollAllWorker` (cron, every 15 min) fans out one
   `PollWorker` per active connection over `draft`/`syncing` documents:
   external booking → compare-then-claim (`externally_booked`); external
   deletion → state `missing` with `reconciliation_results` evidence; live
   drafts refresh the external snapshot/hash so approval drift is
   detectable.
8. Webhooks (§17.11, INV-010) — `POST /webhooks/erp/:endpoint_token`
   resolves the connection by token hash, stores a redacted deduplicated
   receipt, and enqueues an authoritative poll. A webhook is a hint; it
   never directly transitions accounting state.
9. `Sync.retry_operation` (BC-US-106) — authorized manual retry of a failed
   ERP operation: `failed → queued`, sync operation requeued, worker
   re-enqueued; retry re-runs full validation against current mappings.

## State transitions

Intent lifecycle: see the mermaid diagram in invoice-preview-and-freeze
(§11.2 machine; sync states `sync_pending`, `erp_draft`, `approved`,
`booking_pending`, `erp_booked`, `sync_error`). ERP documents: `pending` →
`syncing` → `draft` → `booked`, with `reconciliation_failed` and `missing`
as failure observations. Operations follow the §11.3 machine (see
operations-and-failure-inbox).

## Business rules / invariants

- Every external write carries a stable operation key and idempotency key;
  outcomes are verified by read-back before any lifecycle claim.
- Provider error classification (§22.9.1 mapping): authentication/
  authorization → `block` + connection `action_required`; provider
  validation → `fail`; not_found/conflict → `block`; rate_limited →
  `throttled` retry honoring `retry_after`; provider failure → `transient`
  retry; unsupported capability → `terminal`.
- Retry schedule (§21.3): backoff 0 s, 5 s, 30 s, 2 m, 10 m, 30 m, 2 h with
  ≤20% jitter; at most 7 attempts, then dead-letter.
- `config :billing_core, :erp_writes_disabled` defers execution entirely
  (restore-validation mode, §21.5/§23.9).
- Crash-retried workers tolerate an already-advanced lifecycle
  (idempotent transitions, INV-015).

## GraphQL contract

`erpConnection`, `operation`; `validateErpConnection`,
`synchronizeInvoice` / `bookInvoice` (return an `Operation` to follow —
no HTTP-202 semantics), `approveInvoice`, `retryOperation`.

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

LiveView surfaces under construction; domain commands available via GraphQL.

## Accounting / ERP effects

Draft lines carry product mapping, description, net amount, and — for
over-time lines — accrual dates equal to the half-open service period
converted to inclusive dates. Booking is explicit and approval-gated;
booked documents are never modified (INV-001).

## Async / failure / recovery behavior

All ERP work is durable operations executed by Oban with policy-driven
retries; failures land in the failure inbox (see
operations-and-failure-inbox). Reconciliation mismatches and hash drift
stop automation and require human action.

## Observability

Audit: `erp.connection.*`, `erp.sync.requested`, `erp.invoice.approved`,
`erp.booking.requested`, `erp.operation.manual_retry`. Outbox:
`erp_connection.validated.v1`, `erp_document.draft_created.v1`,
`erp_document.booked.v1`, `erp_document.reconciliation_failed.v1`,
`operation.dead_lettered.v1`. Poll results are persisted in
`reconciliation_results`.

## Tests

`test/workflows/invoice_sync_test.exs` — happy path with accrual
preservation, mapping blockers, unknown-outcome recovery, human-edit
detection, rate-limit retry, cross-team denial.
`test/workflows/external_booking_test.exs` — external booking detection
and external deletion evidence.

## Security / privacy

Credentials are never persisted — only an opaque secret reference; webhook
tokens are stored hashed, payloads redacted to routing fields; provider
errors are stored as sanitized code/summary only.

## Limitations

- Providers: e-conomic adapter plus a fake adapter for tests; sandbox
  certification of accrual behavior against real e-conomic credentials
  remains a release gate (SPEC §1.1).
- One ERP connection per team (v1).
- `sync_error → sync_pending` (`retry_sync`) intent recovery exists in the
  machine; operator flows drive it via `retryOperation`.
