# MCP: monthly customer-credit close

`revryn mcp serve` exposes the monthly customer-credit close workflow
(SPEC BC-US-163…165, BC-TASK-104) to agentic consumers. The tools call the
same public GraphQL commands as the LiveView and CLI surfaces; the MCP
server holds no privileged access and is subject to exactly the
authorization its bearer token grants (INV-045).

The authoritative tool contract — names, schemas, annotations, error
mapping — is
[`clients/revryn/contracts/mcp/tools.md`](../../clients/revryn/contracts/mcp/tools.md).
This page documents the close-specific semantics.

## Safety model

- **Reads are free.** `list_credit_closes`, `get_credit_close`,
  `list_credit_close_policies`, and `get_credit_close_report` are annotated
  `readOnlyHint` and have no side effects.
- **Consequential actions demand explicit confirmation.** Every mutating
  close tool requires `confirm: true` in its input schema; the server
  rejects calls without it *before* any upstream request. Model intent
  alone never posts accounting records.
- **Exactly-once posting.** `generate_credit_close` and `post_credit_close`
  accept an `idempotency_key` (generated when absent, always echoed back).
  Posting additionally searches the ERP by stable external reference before
  any create — a duplicate aggregate voucher is not possible even across
  retries or lost responses.
- **Asynchronous effects are followed, not assumed.** `post_credit_close`
  returns a durable operation reference; consumers follow it with
  `get_operation` until `succeeded`, then re-read the close, which reports
  `reconciled` only after the authoritative provider read-back matched the
  approved report.
- **Evidence is verifiable.** `get_credit_close_report` returns the exact
  stored bytes base64-encoded together with their SHA-256, which matches
  the close's checksum manifest and the report hash bound by approval.

## Recommended agent flow

1. `list_credit_close_policies` — create one with
   `create_credit_close_policy` only if none exists and a human approved
   the journal/accounts.
2. `generate_credit_close` for the target month and currency.
3. `get_credit_close` — present movements, amounts, and the report hash to
   the human for review.
4. `approve_credit_close` (after human review), then `post_credit_close`.
5. Poll `get_operation`; on `succeeded`, `get_credit_close` must report
   `reconciled` with an `externalVoucherNumber`.
6. `accept_credit_close_period` to make the period authoritative.

A failed posting surfaces as a safe tool error plus a durable operation in
state `failed`; remediation is `retry_operation` (also confirm-gated), never
a second create.
