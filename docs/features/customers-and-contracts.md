---
id: customers-and-contracts
title: Customers and contracts
status: supported
public: true
owners: [billing-domain]
graphql:
  - Customer
  - Contract
  - CustomerErpMapping
  - customer
  - customers
  - contract
  - upsertCustomer
  - mapCustomerToErp
  - createContract
tests:
  integration:
    - test/workflows/customer_management_test.exs
adrs:
  - SPEC.md §8.3 Epic C, BC-US-030/031/033
---

# Customers and contracts

## Purpose

Team-scoped customer master data as immutable versioned snapshots, ERP
customer mappings, and contracts as the commercial frame subscriptions and
charges live inside.

## User outcomes

- A billing admin upserts a customer by external ID; every material change
  appends an immutable version (canonical SHA-256 content hash) while
  historical versions stay intact and are provably immutable at the
  database (UPDATE/DELETE rejected).
- An unchanged upsert is an idempotent no-op — no version churn.
- A finance operator connects the customer to an ERP customer number; the
  mapping is `pending` until adapter validation confirms it.
- Contracts are created with an immutable version 1 pinning the customer's
  current version.

## Actors and permissions

Mutations: `billing_admin` or `team_admin` (`upsert_customer_erp_mapping`:
`finance_operator` or `team_admin`). Reads additionally admit
`finance_operator`, `auditor`, `integration_client`. All queries are
team-constrained.

## Domain terminology

- **Customer version** — immutable snapshot of the full customer facts
  (legal name, address, country, email, VAT number, currency preference,
  status) with `content_hash`.
- **Customer ERP mapping** — `(team, customer, erp_connection)` →
  `external_customer_number` with a `validation_status`.
- **Contract version** — immutable snapshot pinning customer version,
  currency, and the effective date window.

## Workflows

1. `Contracts.upsert_customer/2` — locks by `(team, external_id)`; inserts
   customer + version 1, or appends the next version when the canonical
   snapshot changed; emits `customer.version_created.v1`. Invalid facts are
   rejected as a whole — no partial customer.
2. `Contracts.upsert_customer_erp_mapping/3` — insert-or-update per
   `(team, customer, connection)`, default status `"pending"`.
3. `Contracts.create_contract/2` — requires an existing team customer;
   writes contract + `contract_versions` row (version 1, canonical hash).

## State transitions

Customers carry a `status` field (default `active`) stored inside each
version snapshot; contracts are `draft`/`active`. No state machine.

## Business rules / invariants

- Customer facts are immutable versioned snapshots; the same external ID is
  unique per team but reusable across teams (BC-US-030).
- Idempotence is content-based: an upsert whose canonical snapshot
  (including status) is unchanged returns `version: nil` and writes nothing.
- Only an `invalid` ERP mapping blocks synchronization (INV-011); `pending`
  does not.
- Contract currency is fixed at creation; charge instances must match it.
- Subscriptions must start inside the contract's date window (see
  subscriptions doc).

## GraphQL contract

`customer`, `customers` (bounded cursor connection), `contract`;
`upsertCustomer` (idempotencyKey + optional `expectedVersion` optimistic
concurrency → `VersionConflict`), `mapCustomerToErp`, `createContract`.

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

LiveView surfaces under construction; domain commands available via GraphQL.

## Accounting / ERP effects

The frozen customer version snapshot — not the live head — supplies the
invoice recipient during ERP synchronization, so later customer-master
edits cannot rewrite invoice identity (SPEC §17.4).

## Async / failure / recovery behavior

Synchronous transactions only. ERP mapping validation itself happens in the
ERP context asynchronously.

## Observability

Audit: `contracts.customer.version_created`,
`contracts.customer.erp_mapping_upserted`, `contracts.contract.created`.
Outbox: `customer.version_created.v1`.

## Tests

`test/workflows/customer_management_test.exs` — version append semantics,
database-level immutability of versions, idempotent no-op, per-team
uniqueness, authorization matrix.

## Security / privacy

Customer PII lives in team-scoped rows and version snapshots; access
requires a team-resolved scope with a read role. Lists are capped (100).

## Limitations

- No customer archival/merge workflow beyond the `status` field.
- Contract versioning beyond version 1 (amendments) has no command yet.
- ERP mapping adapter validation (`pending → valid/invalid`) is not yet
  automated end to end.
