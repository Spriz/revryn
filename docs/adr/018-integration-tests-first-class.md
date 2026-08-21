# ADR-018 — Integration tests are first-class workflow documentation

Status: accepted
Date: 2026-08-21

## Context and decision

Workflow-level integration tests using real PostgreSQL and application boundaries are prioritized over mock-heavy service-unit testing. External systems are faked only at actual network boundaries.

## Consequences

- Test organization mirrors feature behavior and business workflows.
- Integration tests serve as executable specifications of system behavior.
- Fewer mocks reduce the gap between test and production behavior.
