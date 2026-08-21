# ADR-009 — Draft-first; manual booking by default

Status: accepted
Date: 2026-08-21

## Context and decision

Production starts with finance approval required: invoices are created in draft state and require manual booking by default. Auto-booking is explicitly treated as a policy-controlled optimization, not a default behavior.

## Consequences

- Auto-booking is enabled only after evidence maturity and reconciliation confidence is high enough to justify it.
- Human oversight on invoice booking is the default, supporting compliance and error detection.
- The system supports gradual automation as operational maturity increases.
