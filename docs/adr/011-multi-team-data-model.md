# ADR-011 — Multi-team data model, one legal entity per team

Status: accepted
Date: 2026-08-21

## Context and decision

All domain data is team-scoped, and each team maps to exactly one legal entity and one e-conomic agreement in v1. This scoping model enables future multi-tenancy while keeping the initial implementation clear and verifiable.

## Consequences

- Team isolation is enforced at the database query level for all domain operations.
- Scaling to multiple legal entities per team requires a future ADR and design change.
- Authorization and data access patterns are consistently team-based across the system.
