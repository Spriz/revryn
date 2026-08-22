# ADR-031 — Customer-credit close corrections are compensating closes

Status: accepted
Date: 2026-08-22

## Context

A posted monthly customer-credit close, its transaction-membership set, and
its ERP voucher are immutable (SPEC §17.16, INV-054…057). When an accepted
close later proves wrong — typically a mis-configured posting policy
(journal or accounts) discovered after acceptance, or an authoritative
voucher that a human changed inside the ERP — the correction must not edit
the close, its memberships, or the posted voucher (BC-US-165, §25.9.7).

Two schema invariants shape the solution space: each subledger transaction
belongs to exactly one close forever (`credit_close_transaction_memberships`
is append-only with a global unique `transaction_id`), and the close's
financial snapshot is frozen by a PostgreSQL trigger once `ready`.

## Decision

Corrections are **compensating close rows**, never mutations, and the
original transaction-membership set is never re-membered:

- A close carries a `close_kind`: `regular`, `reversal`, or `replacement`.
- **Reversal**: `request_reversal/3` moves an accepted `closed` close to
  `reversal_pending` and freezes a new `reversal` close for the same period
  with the mirrored bridge (`opening = original closing`,
  `closing = original opening`), linked via `reversal_of_close_id`. Its
  voucher — produced by the ordinary approve → post → reconcile flow with
  the same durable-operation, search-before-create, and read-back rules —
  carries exactly the negated liability line. When the reversal close
  reconciles, the original transitions `reversal_pending → reversed`
  (terminal).
- **Replacement**: `generate_replacement/3` freezes a `replacement` close
  for a `reversed` period under an explicitly chosen (corrected) policy
  version, reproducing the original's exact frozen figures and ledger
  snapshot hash. It reuses the original's canonical evidence for its
  transaction detail; it inserts **no membership rows** — the membership
  set remains, immutably, on the reversed original, referenced through
  `reversal_of_close_id` and the shared `ledger_snapshot_hash`.
- **Continuity**: opening-balance derivation ignores `reversal` closes and
  resolves the newest `regular`/`replacement` close of the preceding
  contiguous period. A `reversed` period without an accepted replacement
  blocks the next generation with `{:previous_close_reversed, id}` — the
  chain never silently skips a correction.
- The period-uniqueness index is partial: one *active* `regular` or
  `replacement` close per team/currency/month; `superseded` and `reversed`
  rows and `reversal` rows are exempt.

Late transactions for an already-closed period remain a separate,
explicitly-approved current-period prior-period-adjustment path (the
`prior_period_adjustment` movement class); silent inclusion stays blocked
by the missed-prior-transaction guard.

## Consequences

- The GL correction story is standard double-entry: wrong voucher, negating
  voucher, correct voucher — each carried by an immutable close row with
  its own report evidence, approval hash, durable operation, and read-back
  reconciliation.
- Membership immutability and the one-close-per-transaction subledger
  invariant survive corrections untouched; auditors trace a corrected
  period as original → reversal → replacement through explicit links.
- Correction closes have `ledger_transaction_count` describing the frozen
  set they represent while owning zero membership rows themselves; report
  consumers must follow `reversal_of_close_id` for the detail rows.
- An accountant must approve the correction procedure before production use
  (release gate) — this ADR fixes the mechanics, not the accounting policy.
