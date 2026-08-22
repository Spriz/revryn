# Capacity review v1 (BC-TASK-077, SPEC §21)

Status: **engineering baseline measured; full-scale certification pending a
production-like environment.** The reproducible suite exists and passes; the
§21.2 aggregate-scale run (100 teams / 100k subscriptions / 10M events/day)
must be repeated on production-sized hardware before this review is marked
accepted. Nothing below is an e-conomic quota claim (SPEC §21.2).

## How to reproduce

```sh
mix test --only performance          # benchmarks, prints [capacity] lines
SOAK_ITERATIONS=300 mix test --only soak
```

Both suites are excluded from the default run and CI; they are capacity
evidence, not regression gates (the asserted floors only catch
order-of-magnitude regressions).

## Measured baseline — 2026-08-22, single dev machine

Linux workstation, single PostgreSQL instance, single BEAM node, FakeERP
provider (in-process GenServer; excludes real network latency to e-conomic).

| Measurement | Result | §21.1 objective | Verdict |
|---|---|---|---|
| Invoice preview, 500 normalized lines (worst of 5 warm runs) | 16.5 ms | 95% < 5 s | pass, ~300× headroom |
| Single usage-event persistence p95 (200 sequential) | 0.3 ms | p95 < 500 ms | pass |
| Batch ingestion throughput (1,000-event batch, one connection) | ~3,300 events/s | 10M/day ≈ 116/s sustained | pass, ~28× headroom on one connection |
| 50 concurrent ERP operations incl. injected rate limits | 221 ms total, exactly one draft each, queue drained | §21.2 concurrency target | pass — correctness preserved, bounded queue |
| Month-boundary partition creation, 12 concurrent workers/inserters | all idempotent, zero failures | §21.2 | pass |
| Soak, 300 mixed iterations (ingest→preview→freeze→sync) | every operation settled, empty failure inbox, BEAM memory growth ≤ 0 MiB | qualitative §21 | pass |

## Deployment sizing assumptions

- One `web` + one `worker` role (or the all-in-one image) saturates far
  below the measured single-node ceilings for the §21.2 targets; PostgreSQL
  is the scaling axis. 10M events/day writes ~116 rows/s sustained into the
  monthly-partitioned `usage_events` — modest for any managed Postgres with
  SSD storage; provision IOPS for the 3–5× daily peak.
- ERP throughput is provider-bound, not Billing-Core-bound: the `erp` queue
  concurrency (10 per node) plus the §21.3 backoff schedule keeps the global
  in-flight count under the 50-operation target; real e-conomic limits must
  be configured from observed response headers (SPEC §21.2).
- Oban queues: `billing:10, erp:10, reconciliation:5, usage:10, email:5,
  maintenance:2, outbox:5` per node; all workers declare bounded
  `max_attempts` (enforced by `test/workflows/failure_matrix_test.exs`).

## Bounded-query audit (§21 acceptance: no unbounded critical path)

| Path | Bound |
|---|---|
| GraphQL connections (customers, subscriptions, products) | keyset cursors, complexity-capped (`max_complexity: 250`, cardinality-weighted) |
| GraphQL list fields (closes, policies, settlements, credit accounts) | closes max 100; settlements limit 200; per-customer credit accounts (small by construction) |
| Operations inbox / recent | inbox filtered by non-terminal states; recent capped at 100 |
| Usage rating | aggregates in SQL over partition-pruned ranges at a frozen cutoff; never loads raw events into memory |
| Batch ingestion | `max_batch_size: 1000`, per-event transactions |
| Billing-run fan-out | one Oban job per team, each processing its own subscriptions via streams/pages |
| Outbox relay | batch-limited polling with a bounded per-run take |

Known deliberate loads: close calculation loads one month × one currency ×
one team of credit transactions (bounded by the monthly close cadence);
audit exports stream per-chain evidence.

## Gaps before "accepted"

1. Re-run on production-like hardware at full §21.2 aggregate scale and
   attach the numbers here — turnkey:

   ```sh
   CAPACITY_SCALE=100 mix test --only performance   # 100k sustained events
   SOAK_ITERATIONS=5000 mix test --only soak
   ```
2. Query plans (`EXPLAIN ANALYZE`) for the top rating/close queries at that
   scale.
3. Provider throttle calibration against real e-conomic response headers —
   blocked on sandbox credentials (see production-readiness review).
