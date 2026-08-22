# revryn credit-closes

Monthly customer-credit close operations over the public GraphQL contract
(SPEC BC-US-163…165, BC-TASK-104). One immutable close per currency and
calendar month bridges the detailed credit subledger to a single aggregate
ERP liability voucher. `revryn` invokes exactly the domain commands
behind the LiveView and MCP surfaces — no privileged path exists.

All commands take the global `--url`, `--token`, `--team`,
`--correlation-id`, and `--json` flags (see
[`clients/revryn/contracts/cli/README.md`](../../clients/revryn/contracts/cli/README.md)).

## Monthly workflow

```sh
# One-time setup: the accountant-approved posting policy.
revryn credit-closes create-policy \
  --effective-from 2026-08-01 --journal 1 \
  --liability-account 2990 --offset-account 5890

# 1. Freeze the month. The very first close of a currency needs an explicit
#    opening balance (zero is valid).
revryn credit-closes generate \
  --currency DKK --period-date 2026-08-15 --bootstrap-opening-minor 0

# 2. Review movements and evidence, download the exact report bytes.
revryn credit-closes get <close-id>
revryn credit-closes report <close-id> --type pdf_summary --out close.pdf

# 3. Approve the exact report hash.
revryn credit-closes approve <close-id> --reason "monthly finance review"

# 4. Post the aggregate voucher. Asynchronous: follow the durable operation.
revryn credit-closes post <close-id>
revryn operations get <operation-id>

# 5. Once reconciled, accept the period as authoritative history.
revryn credit-closes accept <close-id>
```

## Commands

| Command | Effect | Idempotency |
|---------|--------|-------------|
| `credit-closes list [--currency] [--state]` | Read-only listing, newest period first (max 100). | — |
| `credit-closes get <id>` | Read-only close detail with movements and evidence hashes. | — |
| `credit-closes policies` | Read-only policy-version listing. | — |
| `credit-closes create-policy` | Creates the next posting-policy version. | Server rejects duplicates per version. |
| `credit-closes generate` | Freezes one deterministic close for the month containing `--period-date`. | `--idempotency-key` (generated when absent); replay returns the same close. |
| `credit-closes approve <id>` | Approves the exact frozen report hash. | State machine guards re-approval. |
| `credit-closes post <id>` | Creates the durable ERP posting operation (search-before-create; no duplicate voucher). | `--idempotency-key` (generated when absent). |
| `credit-closes accept <id>` | Accepts a reconciled close as the period's authoritative history. | State machine guards re-acceptance. |
| `credit-closes report <id> --type <t> [--out f]` | Downloads one immutable evidence file's exact bytes; the printed SHA-256 matches the close manifest. | — |
| `credit-closes reverse <id> --reason` | Freezes a compensating reversal close (mirrored bridge) for an accepted close (ADR-031); approve and post it to cancel the original voucher. | State machine guards double reversal. |
| `credit-closes replace <id> --policy-version --reason` | Freezes a replacement close for a reversed period under the corrected policy, hash-verified against the frozen membership. | One active close per period is DB-enforced. |

Evidence types: `canonical_json`, `csv_detail`, `pdf_summary`, `manifest`,
`erp_voucher`, `erp_attachment`, `reconciliation`.

## Failure and remediation

A failed or mismatched posting keeps the close and its error evidence; it
never creates a partial voucher. Inspect the durable operation
(`revryn operations list` / `get`) and retry it
(`revryn operations retry <operation-id>`) after remediation — the
stable operation key guarantees the provider is searched before any create.

## Exit codes and JSON

The standard `revryn` exit-code and `--json` envelope contract applies
([`exit-codes.md`](../../clients/revryn/contracts/cli/exit-codes.md));
close commands add no special cases. Machine-readable outputs mirror the
GraphQL types in `schema/billing_core.graphql`.
