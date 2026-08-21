---
id: annual-prepaid-subscriptions
title: Annual prepaid subscriptions
status: supported
public: true
owners: [billing-domain]
graphql:
  - Subscription
  - createSubscription
  - invoicePreview
  - freezeInvoiceIntent
tests:
  unit:
    - test/unit/domain/period_test.exs
    - test/unit/pricing
  integration:
    - test/workflows/annual_prepaid_subscription_test.exs
    - test/workflows/invoice_sync_test.exs
adrs:
  - SPEC.md §27 ADR-005, ADR-006, ADR-015
---

# Annual prepaid subscriptions

## Purpose

Bill a fixed annual amount in advance while preserving the full service
period on the invoice line so e-conomic can post the revenue accrual over
time. This is the minimal vertical slice of the platform (SPEC §1.2).

## User outcomes

- Customer operations starts an annual subscription on a published plan
  version with an explicit start date and quantity.
- A finance operator previews the invoice, sees one line carrying the full
  annual amount and the half-open service period, freezes it into immutable
  invoice intent, and synchronizes it to an e-conomic draft.
- The draft's accrual dates equal the service period converted to inclusive
  dates (`[2026-09-15, 2027-09-15)` → `2026-09-15 … 2027-09-14`).

## Actors and permissions

- `billing_admin`: plans, subscriptions.
- `finance_operator`: preview, freeze, synchronize, approve.
- `auditor`: read-only trace access.

## Domain terminology

See SPEC §9. Key facts: periods are half-open date intervals; money is
integer minor units; the plan version is immutable once published.

## Workflows

1. Create product with `over_time` recognition policy → map to e-conomic
   product whose product group has accrual configuration.
2. Publish plan version with a fixed recurring component, 12-month interval,
   `in_advance` timing.
3. Create customer (+ e-conomic mapping) and contract; start subscription.
4. Billing run selects the subscription, rates the full period, produces one
   charge with the complete service period.
5. Preview → freeze invoice intent (canonical snapshot + SHA-256).
6. Durable sync operation creates the ERP draft, reads it back, reconciles
   header/lines/amount/accrual dates.

## Business rules / invariants

- INV-004: the over-time line must carry `service_start`/`service_end_exclusive`.
- INV-007: canonical periods half-open; adapter converts to inclusive.
- INV-013: pricing inputs snapshotted before external effects.
- Amount: `fixed_unit_price × quantity` (SPEC §10.1), rounded
  half-away-from-zero at the final line only.

## Accounting / ERP effects

One draft invoice line: `quantity=1`, `unitNetPrice=<final amount major
units>`, `accrual.startDate`/`accrual.endDate` present. Booking is manual by
default.

## Async / failure / recovery behavior

Synchronization is a durable operation (SPEC §11.3): retries per §21.3,
`outcome_unknown` reconciles by external reference before any retry, terminal
failures surface in the failure inbox.

## Observability

`billing_runs_total`, `invoice_intents_total{state}`,
`erp_operations_total`, spans for rate/freeze/sync; correlation IDs from the
initiating command through the ERP write.

## Tests

- `test/workflows/annual_prepaid_subscription_test.exs` — the full slice:
  preview → freeze → sync → reconcile → approve → book; mid-period
  proration; supersession immutability.
- `test/workflows/invoice_sync_test.exs` — draft reconciliation with
  accrual dates preserved, mapping blockers, unknown-outcome recovery.

## Limitations

- The domain slice is supported end to end against the adapter contract;
  sandbox certification of accrual behavior against real e-conomic
  credentials is still a release gate (SPEC §1.1).
