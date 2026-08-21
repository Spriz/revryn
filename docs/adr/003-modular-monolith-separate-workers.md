# ADR-003 — Modular monolith with separate workers

Status: accepted
Date: 2026-08-21

## Context and decision

We will deploy as a single codebase and database, but with separate API, worker, and admin processes. This monolith design is deliberate: financial invariants benefit from local transactions and a small operational footprint.

## Consequences

- All processes share the same database and codebase, enabling ACID transactions for financial operations.
- Separate deployment processes allow independent scaling and operational concerns.
- The system remains relatively simple while still supporting concurrent execution patterns.
