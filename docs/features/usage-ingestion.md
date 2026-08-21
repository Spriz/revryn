---
id: usage-ingestion
title: Usage ingestion
status: supported
public: true
owners: [billing-domain]
graphql: []
tests:
  integration:
    - test/workflows/usage_ingestion_test.exs
    - test/workflows/metered_billing_test.exs
adrs:
  - SPEC.md §8.4 Epic D, §13.1, §18.5, BC-US-050…055
---

# Usage ingestion

## Purpose

Idempotent ingestion of usage measurements, immutable void/replacement
corrections, quarantine instead of silent loss, and cutoff-reproducible
aggregation feeding metered billing.

## User outcomes

- An integration submits events (single or batch) exactly-once by external
  event ID: identical replays are `duplicate`, changed payloads `conflict`.
- Problem events (unknown subscription, too old, too far in the future,
  oversized properties) are quarantined with the full payload — never
  silently discarded; a later accepted re-ingest resolves the entry.
- Finance can reproduce any billing quantity: aggregation at a frozen
  cutoff always returns the same evidence set.

## Actors and permissions

Ingestion and corrections: `integration_client`, `billing_admin`, or
`team_admin`. Reads/aggregation additionally `finance_operator` and
`auditor`. All operations are team-scoped.

## Domain terminology

- **Event key** — unpartitioned `(team, external_event_id)` reservation
  with payload hash; the idempotency authority.
- **Measurement / void / replacement** — `usage_events` kinds. A void
  references the original; a replacement is an ordinary measurement linked
  via `replacement_for_event_id`.
- **Cutoff evidence set** — measurements received on or before the cutoff
  with no void received on or before that same cutoff.

## Workflows

1. `ingest_event` — normalizes (`occurred_at` UTC, decimal `value`,
   canonical `properties` without floats), resolves the subscription by
   internal or external ID, applies policy limits, reserves the event key
   (`ON CONFLICT DO NOTHING`), inserts the measurement. `received_at` is
   assigned by PostgreSQL `clock_timestamp()` and never accepted from
   callers.
2. `ingest_batch` (BC-US-051) — each event in its own transaction; one
   failing event never rolls back siblings; batches over the cap fail up
   front (`:batch_too_large`). When ≥1 event is accepted, exactly ONE
   `usage_batch.accepted.v1` outbox event carries the batch counts.
3. `void_event` (BC-US-052) — the void has its OWN external event ID (the
   correction's idempotency key); optional replacement in the same locked
   transaction. Both copy the original's `occurred_at` (partition locality)
   and record their own server `received_at` (cutoff semantics).
4. `aggregate` (BC-US-053/054/055) — pure read over a half-open billing
   period at a frozen cutoff; `sum` (default), `count`, `max`,
   `unique_count` (distinct values of a properties key). Late-received
   in-period measurements are reported as `excluded_late`.
5. `ensure_partitions` / `PartitionWorker` — monthly partitions kept ≥ 2
   months ahead (daily cron 03:00); there is no DEFAULT partition, so an
   `occurred_at` outside created partitions raises.

## State transitions

Event status: `effective` → `voided` (lifecycle projection only — all
payload columns stay frozen; a database trigger rejects any other change).
Quarantine entries: open → `resolved_at` set on accepted re-ingest.

## Business rules / invariants

- At most one effective void per measurement (partial unique index):
  replaying the same void ID is idempotent (`{:ok, :already_voided}`), a
  second different void is `{:error, :already_voided}`.
- A void received after a cutoff does NOT remove the measurement from that
  cutoff's evidence — reproducibility over recency.
- Period assignment: the DATE of `occurred_at` in the team's billing time
  zone (UTC-date fallback when the zone is unknown to the tz database).
- Policy limits (module config, defaults): `max_age_days` 90,
  `max_future_hours` 24, `max_batch_size` 1000, `max_properties_bytes`
  65,536.

## GraphQL contract

None yet — ingestion, correction, and aggregation are Elixir context
functions only (see Limitations).

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

LiveView surfaces under construction; domain commands available via GraphQL.

## Accounting / ERP effects

None directly. Metered invoice lines embed the aggregation evidence
(metric, aggregation, event count, excluded_late, cutoff) in their
calculation trace (see invoice-preview-and-freeze).

## Async / failure / recovery behavior

Batch items survive storage-level raises (e.g. missing partition) as
per-item `storage_error` rejections without losing committed siblings.
Recalculation of already-billed periods is driven downstream by the
`usage_event.voided.v1` event (credit/rebill — not yet automated).

## Observability

Audit: `usage.event.quarantined`, `usage.event.voided`. Outbox:
`usage_batch.accepted.v1`, `usage_event.voided.v1`.

## Tests

`test/workflows/usage_ingestion_test.exs` — idempotency triad, server
`received_at`, quarantine + resolution, batch independence and the single
batch event, void/replacement cutoff semantics, all four aggregations,
isolation/authorization. `test/workflows/metered_billing_test.exs` —
usage → graduated-tier invoice lines with traces.

## Security / privacy

Properties are canonicalized JSON without floats; oversized payloads are
quarantined, not stored unbounded. Cross-team ingest/void/aggregate is
uniformly denied.

## Limitations

- No GraphQL/HTTP ingestion endpoint yet — context API only.
- No automated credit/rebill pipeline reacting to voids of already-billed
  periods; `usage_event.voided.v1` is emitted for a future consumer.
- Quarantine review/replay tooling is limited to re-ingesting the corrected
  event.
