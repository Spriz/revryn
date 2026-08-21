---
id: corrections-and-credit-notes
title: Corrections and credit notes
status: supported
public: true
owners: [billing-domain]
graphql: []
tests:
  integration:
    - test/workflows/correction_test.exs
adrs:
  - SPEC.md INV-001/002, BC-US-102/103/104
---

# Corrections and credit notes

## Purpose

Correct booked invoices without ever mutating them (INV-001): a correction
opens a case linking the original intent to a compensating credit-note
intent whose lines are exact or partial negatives of the original lines
(INV-002).

## User outcomes

- Full credit (BC-US-102): every original line is exactly negated; the
  credit note preserves product, product version, quantity, service period,
  and recognition mode, and books as a credit document.
- Partial credit (BC-US-103): selected amounts per line; cumulative credits
  across all non-superseded credit notes can never exceed the original line
  amount.
- Every credit intent flows through the normal draft → approval → booking
  states.

## Actors and permissions

`finance_operator` only. The original intent must belong to the scope's
team and be in state `erp_booked`.

## Domain terminology

- **Correction case** — `correction_cases` row linking the original intent,
  its booked ERP number, the credit intent, and optionally a replacement
  intent; carries reason code and narrative; status starts
  `credit_pending`.
- **Credit line** — negative-amount line with
  `adjusts_line_id` → the original line and a calculation trace recording
  source line, source amount, and credited amount.

## Workflows

1. `Corrections.create_full_credit/3` or `create_partial_credit/4`
   (allocations are `{line_key, positive_minor_units}` pairs).
2. In one transaction: the original intent transitions
   `erp_booked → credit_required` (`correction_approved`); a credit intent
   (`document_kind: "credit_note"`, new chain) is frozen with the negated
   lines; the case row is inserted; the original transitions back
   `credit_required → erp_booked` (`correction_case_created`, the case ID
   as reason).
3. The credit intent is then synchronized/approved/booked like any intent
   (see erp-synchronization); `correction_test.exs` verifies the booked
   credit document carries the negative total and preserved accrual period.

## State transitions

Original intent: `erp_booked → credit_required → erp_booked` (see the
§11.2 machine in invoice-preview-and-freeze). Credit intent: the normal
intent lifecycle from `frozen`. Case status: `credit_pending` (no further
automated status flow yet).

## Business rules / invariants

- INV-001: booked means immutable — no update or delete ever reaches a
  booked document.
- INV-002: corrections are compensating documents, not edits.
- Cumulative bound per line: prior credit allocations (summed across all
  credit-note intents referencing the line whose lifecycle is not
  `superseded`) plus the requested amount ≤ the original line amount;
  violations return `{:credit_exceeds_original, line_key, details}`.
- Credit amounts must be positive integers against known line keys.
- The credit intent reuses the original's customer identity from the frozen
  snapshot and its usage cutoff; invoice date defaults to today.

## GraphQL contract

None yet — corrections are Elixir context commands
(`BillingCore.Billing.Corrections`). Credit intents are visible through
`invoiceIntent`.

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

LiveView surfaces under construction; domain commands available via GraphQL.

## Accounting / ERP effects

The credit note books in the ERP as a separate compensating document;
over-time credit lines carry the original service period so the accrual
reverses over the same range. The original booked invoice number is
recorded on the case.

## Async / failure / recovery behavior

Case creation is one transaction (illegal intent states roll everything
back). Downstream sync/booking of the credit intent uses the durable
operation machinery with its retry policy and failure inbox.

## Observability

Audit: `billing.correction.opened`. Outbox: `correction_case.opened.v1`;
subsequent credit-document sync emits the standard `erp_document.*` events.

## Tests

`test/workflows/correction_test.exs` — full credit booking as a credit
note with preserved periods, cumulative partial-credit bounds, booked-state
and role preconditions.

## Security / privacy

Finance-role gated; the case records the creating actor; credit lines
carry only accounting data already present on the original intent.

## Limitations

- Replacement invoices (BC-US-104): the case schema has
  `replacement_invoice_intent_id`, but no command creates a replacement
  intent yet.
- No case status workflow beyond `credit_pending` (e.g. closing a case when
  the credit note books) and no GraphQL/UI surface.
- Customer-credit funding from a credit note (ledger grant with
  `origin_invoice_line_id`) is a manual follow-up via the credits context.
