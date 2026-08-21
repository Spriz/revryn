# ADR-030 — Transactional domain events, not event sourcing, for v1

Status: accepted
Date: 2026-08-21

## Context and decision

State-changing domain transactions may emit versioned domain events through the PostgreSQL transactional outbox. Current Ecto row state plus immutable audit evidence remains authoritative. Do not adopt Commanded/EventStore/CQRS event sourcing for v1.

## Consequences

- Downstream workflows and future integrations can be event-driven while accounting-critical invariants remain synchronous and strongly consistent.
- Event sourcing requires a future ADR backed by concrete replay/projection requirements before adoption.
- The transactional outbox provides event-driven capability without the operational complexity of a full event store.
