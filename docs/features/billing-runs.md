---
id: billing-runs
title: Billing runs
status: supported
public: true
owners: [billing-domain]
graphql:
  - BillingRun
  - billingRun
  - createBillingRun
tests:
  integration:
    - test/workflows/billing_run_test.exs
adrs:
  - SPEC.md §18, BC-US-066/116
---

# Billing runs

## Purpose

Deterministic, re-runnable billing: one run per stable run key selects
eligible subscriptions at their billing boundary, rates them, records
double-billing-guarded charges, and freezes one consolidated invoice intent
per customer.

## User outcomes

- The nightly scheduler (or an operator) processes the regular run for a
  date; re-running the same run key never double-bills — already-billed
  occurrences are skipped, not duplicated (SPEC §18.4).
- Charges of one customer/currency consolidate into a single invoice intent
  per run (BC-US-066).
- A run cannot be closed while any of its intents is unresolved
  (BC-US-116).

## Actors and permissions

`open_run`: `billing_admin`, `team_admin`, or `finance_operator`.
`close_run`: `finance_operator` or `team_admin`. The scheduled path runs
under a synthetic scheduler scope (machine actor, SPEC §6.2).

## Domain terminology

- **Run key** — deterministic identity, `<invoice-date>:regular:<tz>` for
  regular runs (time zone slashes replaced with dashes); unique per team.
- **Occurrence key** — `subscription:component:service_start:service_end:kind`;
  the double-billing guard unit.
- **Usage cutoff** — local midnight of the invoice date in the team's time
  zone, converted to UTC; stamped on the run and every intent.

## Workflows

1. `Billing.open_run/2` — idempotent by `(team, run_key)`; a concurrent
   creation race resolves through the database unique constraint to the
   existing run.
2. `Scheduler.process_regular_run/2` —
   - selects eligible subscriptions (§18.2): `active` or
     `pending_cancellation`, started, not ended, stable-ordered by customer
     then subscription;
   - previews each; skips with explicit reasons: `{:blocked, blockers}`,
     `:nothing_to_bill`, `:not_a_billing_boundary` (in-advance billing: the
     run date must equal the billing-period start);
   - groups previews by `{customer, currency}` and freezes one intent per
     group, with the run's invoice date and usage cutoff.
3. Per line: a per-occurrence advisory lock (§18.3) is taken, then
   `Billing.record_charge!/2` inserts the immutable rated charge — the
   active-occurrence unique index (`charges_active_occurrence_uq`) rejects
   a second active charge for the same occurrence
   (`{:error, :occurrence_already_billed}`). Groups whose lines were all
   already billed are skipped.
4. `Billing.close_run/2` — refused (`{:error, :unresolved_intents}`) while
   any run intent is in `frozen`, `sync_pending`, `sync_error`, or
   `booking_pending`.
5. `Billing.RunWorker` — daily 02:00 cron tick fans out one Oban job per
   active team with that team's local date; per-team jobs are unique.

## State transitions

Runs: `open` → `closed`. Charges: `status` `active` (a superseded-charge
flow is not yet implemented). Intent states are documented in
invoice-preview-and-freeze.

## Business rules / invariants

- One run per run key; open is idempotent, including under concurrency.
- Every subscription/period/component occurrence is billed at most once
  while its charge is active (advisory lock during calculation + unique
  constraint as the durable guard).
- Consolidation is per team/customer/currency/invoice-date within a run;
  different customers always get separate intents.
- Freezing inside the run stamps `billing_run_id`, the run's invoice date,
  and the run's usage cutoff on the intent.

## GraphQL contract

`createBillingRun` (stable `runKey`; reopening returns the existing run),
`billingRun`.

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

LiveView surfaces under construction; domain commands available via GraphQL.

## Accounting / ERP effects

None directly — the run produces frozen intents; synchronization and
booking are separate, explicitly requested workflows.

## Async / failure / recovery behavior

The scheduled tick and per-team jobs are Oban jobs (queue `billing`,
unique per hour); the run key + occurrence guard make any retry or
re-execution safe. Skipped subscriptions are reported with reasons rather
than failing the run.

## Observability

Audit: `billing.run.opened`, `billing.run.closed`. Outbox:
`billing_run.opened.v1`. Runs record `engine_version` and
`settings_version` for reproducibility.

## Tests

`test/workflows/billing_run_test.exs` — boundary selection and per-customer
consolidation, re-run without double billing, close protection, customer
separation.

## Security / privacy

Team-scoped runs; close requires finance/team-admin role of the owning
team.

## Limitations

- In-arrears billing timing is not yet selected by the boundary logic
  (in-advance only: run date = period start).
- No GraphQL mutation for closing a run; `close_run` is context-level.
- Charge supersession (deactivating a charge to re-bill an occurrence) has
  no command yet.
