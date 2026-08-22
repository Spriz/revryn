# revryn credits

Customer-credit subledger surface (SPEC BC-US-107…109, §9.4.1). Credit is
money-like settlement value, never a discount (INV-050); every mutation is a
typed GraphQL command with the same authorization as the other interfaces.

## Reads

```sh
revryn credits accounts --customer-id <uuid>
revryn credits settlements [--invoice-intent-id <uuid>] [--state pending|reconciled]
```

`accounts` shows each linked credit account with available/reserved balances,
grants, append-only transactions, and the current disposition policy.
`settlements` lists the receivable settlements opened by credit applications
with their mode, state, and reconciliation evidence (external reference or
ERP voucher number).

## Mutations

```sh
revryn credits grant --account-id <uuid> --amount-minor 20000 \
  --currency DKK --origin-type goodwill --idempotency-key grant-2026-08-a

revryn credits set-disposition --account-id <uuid> \
  --policy expire_after --expire-after-days 90

revryn credits settle-external --settlement-id <uuid> --reference remit-42
```

`grant` requires a stable `--idempotency-key`; replays with the same key are
safe. `settle-external` reconciles a pending `external_reference`-mode
settlement exactly once — replaying the same reference is idempotent, a
different reference is refused.

## Settlement mode on the posting policy

`revryn credit-closes create-policy` accepts `--settlement-mode`
(`none`, `erp_customer_settlement`, `external_reference`) plus
`--settlement-clearing-account`/`--settlement-contra-account` for the ERP
mode. Automatic credit application stays blocked until a mode is certified
(SPEC §9.4.1); see `docs/accounting/customer-credit-close.md`.
