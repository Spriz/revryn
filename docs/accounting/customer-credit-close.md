# Customer-credit close accounting contract

## Scope

Revryn is the detailed customer-credit subledger. e-conomic is the general
ledger and receives a monthly aggregate customer-credit liability close for
one team, one currency, and one accounting month. This is a constrained
finance-voucher integration, not a generic journal adapter.

## Aggregate posting rule

Each close has exactly one liability-account line. It is the debit-positive
minor-unit amount:

```text
economic_liability_line = opening_minor - closing_minor
```

The balancing side is either one configured aggregate offset or
accountant-approved aggregate movement-class lines. No line may contain a
customer/customer-number dimension, individual credit grant/application/
refund/expiry, invoice-line detail, or VAT code. The voucher is VAT-neutral;
it does not replace a required invoice, credit note, receivable settlement,
refund record, or tax treatment.

| Balance movement | Example (DKK) | Debit-positive liability line | Posting meaning |
| --- | --- | ---: | --- |
| Increase | opening 1,000.00 → closing 1,200.00 | -200.00 | Credit the liability account; debit aggregate offset(s) |
| Decrease | opening 1,200.00 → closing 1,000.00 | +200.00 | Debit the liability account; credit aggregate offset(s) |
| Zero | opening 1,000.00 → closing 1,000.00 | 0.00 | Keep the report; voucher creation follows approved zero-delta policy |

The accounting month follows the team's accounting time zone and is a
half-open period. The posting date, journal, liability account, offset
mapping, and zero-delta behavior are taken from the immutable policy version
frozen into the close.

## Evidence and control trail

Before e-conomic is written, the close freezes its opening and closing
balances, membership set, cutoff, movement totals, policy version, canonical
ledger snapshot hash, canonical JSON, CSV transaction detail, PDF summary,
and SHA-256 manifest. The PDF is attached to the voucher; the manifest binds
the evidence to the stable voucher reference:

```text
REVRYN:CREDIT-CLOSE:<close-id>:<YYYY-MM>:<currency>
```

Read-back must match journal, date, currency, accounts, signs, amounts,
stable reference, and attachment metadata before the close is reconciled.
The close and its membership set are immutable after posting. The detailed
ledger remains the source for customer-level audit information; the ERP has
only the reconciled aggregate.

## Exception handling

If an ERP request times out after possible commit, the operation is
`outcome_unknown`. Search by known voucher ID/reference and bounded
journal/accounting-year/date/account/currency/amount criteria before any
retry. Retry only after absence is proven, using the same durable operation
and idempotency key.

If the authoritative voucher differs or several plausible vouchers exist,
mark the close `mismatch`, stop automatic posting, and preserve all frozen
evidence. Do not amend the posted voucher or close. Finance remediates with
an approved reversal/replacement close or current-period prior-period
adjustment, then rechecks the replacement voucher, attachment, evidence hash,
and next-period opening continuity.

The implemented correction mechanics
([ADR-031](../adr/031-credit-close-corrections-are-compensating-closes.md)):
a reversal is a compensating close for the same period with the mirrored
bridge (opening/closing swapped, deltas negated) whose voucher cancels the
wrong posting; when it reconciles, the original becomes `reversed`. A
replacement close then reproduces the original's exact frozen figures —
recomputed from the immutable transaction membership, hash-verified — under
the corrected policy and reposts. Opening continuity resolves through the
replacement; a reversed period without one blocks the next month's close.
Both corrections require an explicit recorded reason and pass through the
ordinary approval and read-back reconciliation gates.

Late registrations: a transaction that *occurs* after an accepted cutoff
with a prior-period accounting date is swept into the next close and
classified `prior_period_adjustment` automatically. A transaction the
accepted close *should have seen* (occurred at or before its cutoff, yet
unmembered) blocks the next generation; finance may include it explicitly
via the audited `approved_prior_period_transaction_ids` generation input,
which records the approval and classifies the movement as a current-period
prior-period adjustment. Silent backdating into a closed membership set is
impossible in both paths.

## Receivable-settlement mode (SPEC §9.4.1)

The posting-policy version also declares which system owns open
receivables. Automatic credit application is blocked until a mode is
certified:

- `erp_customer_settlement` — when a credit-covered invoice books, Billing
  Core posts a two-line, VAT-neutral clearing voucher: debit
  `settlement_clearing_account_number`, credit
  `settlement_contra_account_number`, both declared on the policy version.
  The monthly liability close reconciles the clearing account in
  aggregate; the settlement voucher is the per-invoice drill-down. The
  voucher never carries customer or VAT dimensions — the invoice retains
  the full revenue/VAT facts.
- `external_reference` — the authoritative external receivables system
  settles the invoice; finance records its reference exactly once and the
  settlement record is the reconciliation evidence.

The monthly aggregate close alone never marks an invoice paid.

## Approval boundary

This document defines the engineering contract, not accounting advice. An
accountant must approve the configured accounts, journal, posting date,
debit/credit mapping, first opening balance, zero-delta behavior, refund and
expiry treatment, the receivable-settlement mode with its clearing/contra
accounts, correction process, and retention policy before use.
