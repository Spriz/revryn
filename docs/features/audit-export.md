---
id: audit-export
title: Audit export and retention
status: supported
public: true
owners: [billing-domain]
graphql:
  - auditExport
tests:
  integration:
    - test/graphql/audit_export_test.exs
    - test/unit/audit_export/retention_test.exs
adrs:
  - SPEC.md §20, BC-US-114, BC-TASK-072, INV-018
---

# Audit export and retention

## Purpose

An auditor reconstructs any invoice chain from a self-contained, checksummed
evidence package without database access, and every table in the billing
schema carries an explicit retention classification enforced by allowlisted
automation only.

## GraphQL contract

`auditExport(teamId, invoiceIntentId)` returns the chain package: canonical
JSON evidence files (the chain, every immutable intent version with
calculation traces and state transitions, ERP documents and sync
operations, approvals, and audit-log entries) plus a SHA-256 checksum
manifest covering every file. Auditor role suffices; cross-team access is
denied identically to a missing chain.

## Retention classes

`schema/audit.yaml` (generated from `BillingCore.AuditExport.Retention`,
sync-tested, completeness-gated against the live schema) classifies every
table: `financial_evidence` (six-year-plus accountant-approved hold, never
pruned by automation), `identity_access`, `operational` (nightly
allowlist-only pruning with audited counts), and `raw_usage`
(team-configurable after invoice freeze, 90-day floor, gated deletes). See
`docs/accounting/retention.md` for the policy and
`BillingCore.Privacy.erase_customer/3` for the erasure procedure.

## Tests

`test/graphql/audit_export_test.exs` — chain reconstruction, checksum
integrity, auditor access, cross-team denial, credential absence.
`test/unit/audit_export/retention_test.exs` — classification completeness,
YAML sync, financial-hold clamp, allowlist pruning, raw-usage window.

## Limitations

- Export is per invoice chain; a whole-period bulk export composes chain
  exports client-side (CLI orchestration planned with BC-US-157 tail).
