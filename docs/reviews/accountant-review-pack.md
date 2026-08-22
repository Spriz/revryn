# Accountant review pack (release gate 2)

Everything a Danish accountant needs to review and sign off, in reading
order. Each item links the authoritative document — nothing is duplicated
here (INV-021).

## Reading order

1. `docs/accounting/customer-credit-close.md` — the monthly close
   contract: journal, liability account, `opening − closing` line sign,
   posting date, zero-delta behavior, movement classes, correction
   procedure (ADR-031 reversal/replacement), prior-period handling, and
   the §9.4.1 receivable-settlement modes with clearing/contra accounts.
2. `docs/accounting/retention.md` — six-year financial hold, operational
   pruning allowlist, team-configurable raw-usage retention, erasure.
3. `docs/adr/031-credit-close-corrections-are-compensating-closes.md`.
4. `docs/reviews/economic-sandbox-certification.md` — generated evidence
   from the real sandbox once credentials are supplied (gate 1).

## Sign-off checklist

For each line: approve, or state the required change.

- [ ] Journal number and customer-credit liability account
- [ ] Offset/balancing account(s) and `movement_account_map` classes
- [ ] Exact `opening − closing` e-conomic line sign convention
- [ ] Posting date = period end (last day of month)
- [ ] Zero-delta months post no voucher (default) — or always post
- [ ] Refund treatment (durable obligation; rail outside Billing Core)
- [ ] Expiry/write-off treatment and VAT position
- [ ] First opening balance procedure (imported/approved or zero)
- [ ] Correction procedure: reversal + replacement closes, never edits
- [ ] Receivable-settlement mode (none / erp_customer_settlement /
      external_reference) + clearing and contra account numbers
- [ ] Financial retention period (≥ 6 years; jurisdictional floor)
- [ ] Invoice accrual/service-period field mapping (sandbox report §17)

Signed: ______________________  Date: ____________
