# ADR-029 — Explicit transactional state machines for non-trivial lifecycles

Status: accepted
Date: 2026-08-21

## Context and decision

Model non-trivial persisted lifecycles as explicit state machines with PostgreSQL/Ecto remaining authoritative. Run an M0 spike comparing current Finitomata with a deliberately small pure internal state-machine abstraction. Prefer Finitomata if it provides executable definitions, diagram generation, guards, telemetry, and testing without moving transaction/concurrency authority into long-lived FSM processes.

## Consequences

- Subscription, invoice, operation, ERP-sync, correction, and recovery lifecycle rules are centralized and mechanically testable.
- `:gen_statem` remains available for process/protocol state machines but is not the persistence model for database aggregates.
- State transitions are explicit and auditable through the database.
