# Data retention policy (engineering contract)

Scope: what Revryn keeps, for how long, and what automation may delete
(SPEC §20, BC-TASK-072). The machine-readable classification lives in
[`schema/audit.yaml`](../../schema/audit.yaml), generated from
`BillingCore.AuditExport.Retention`; a test fails when a database table
exists without a classification, so this policy cannot silently drift.

## Classes

**Financial evidence** — frozen invoice intents, calculation traces,
correction chains, the customer-credit subledger, close memberships and
reports, manifests, ERP document/voucher snapshots, sync operations,
approvals, reconciliation results, the audit log, and the commercial
catalog/contract history they reference. Automation never deletes any of
it. Default hold: **six years** from creation
(`financial_retention_years`, configurable upward only — the code clamps
below-default values up). Deletion or archival after the hold requires the
accountant-approved procedure; `AuditExport.Retention.financial_hold_until/1`
gives the earliest instant a record may even be considered.

**Identity and access** — users, credentials, memberships. Retained while
the identity or membership is live plus the approved tail; every change is
itself an audit fact in financial evidence.

**Operational machinery** — delivery, dedup, and diagnostic rows whose
durable truth lives in financial evidence: redacted webhook receipts,
published outbox events, expired idempotency records, dead sessions, and
demo-workspace bookkeeping. The nightly `RetentionWorker` (02:30 UTC)
prunes these after per-table windows:

| Table | Qualifies for pruning | Default window |
|-------|----------------------|----------------|
| `webhook_receipts` | received before cutoff | 90 days |
| `outbox_events` | published before cutoff | 30 days |
| `idempotency_records` | expired before cutoff | 30 days |
| `sessions` | revoked/expired before cutoff | 30 days |

Windows are configured under `config :billing_core, :retention`. Every run
records a `retention.operational_prune_completed` audit fact with per-table
counts and emits `[:billing_core, :retention, :pruned]` telemetry. The
pruning code is allowlist-driven: it is structurally unable to touch a
table outside this list.

## Raw-usage retention (team-configurable)

Raw usage events belong to the dedicated `raw_usage` class (SPEC §20): once
an invoice freeze has consumed them, the frozen calculation traces are the
financial evidence and the raw rows are dispute/replay material with a
team-declared hold. Teams opt in with the `raw_usage_retention_days`
setting (Settings → Data retention), clamped to a 90-day floor. The
nightly retention job deletes only rows both past the window and before
the team's newest frozen usage cutoff, through a transaction-scoped
database gate — no other code path can delete usage rows, and the dedup
ledger (`usage_event_keys`) is never pruned, so a deleted event replayed
by an integration still deduplicates. Every prune is audited with counts.

## Erasure requests

`BillingCore.Privacy.erase_customer/3` (team admins, reason required)
pseudonymizes a customer's operational personal data going forward by
appending a redacted immutable version through the ordinary customer
command; it is refused while live subscriptions exist. Historical version
snapshots and frozen invoice evidence are retained — redactable only under
the approved bookkeeping/privacy procedure — so close continuity and
voucher traceability never break. Every erasure is audited
(`privacy.customer_erased`) and emitted as `customer.erased.v1`.

## Approval boundary

This document is the engineering contract, not accounting or legal advice.
An accountant must approve the effective retention period, the erasure
procedure, and any archival of financial evidence before production use;
the six-year default reflects the Danish Bookkeeping Act's baseline and is
a floor, not a decision.
