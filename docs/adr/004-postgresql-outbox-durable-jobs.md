# ADR-004 — PostgreSQL outbox and durable jobs

Status: accepted
Date: 2026-08-21

## Context and decision

PostgreSQL provides transactional outbox and job leasing primitives in v1. We will not introduce an external message broker; instead, we will rely on PostgreSQL for both transactional outbox events and durable job scheduling.

## Consequences

- No external broker is required, reducing operational complexity and deployment footprint.
- All event handlers and job processors must remain idempotent so that a broker can be added later if needed.
- Retry and failure handling must work within PostgreSQL's capabilities and semantics.
