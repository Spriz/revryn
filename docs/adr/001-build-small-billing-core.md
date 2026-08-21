# ADR-001 — Build a small billing core rather than fork Lago

Status: accepted
Date: 2026-08-21

## Context and decision

Forking a broad billing platform creates upgrade, licensing, and conceptual complexity. We will implement only the commercial pricing and invoice-intent capabilities required by this product rather than maintaining a fork of Lago or another comprehensive billing system. The required system is smaller and has a deliberately different accounting boundary.

## Consequences

- Advanced billing-platform features are consciously excluded and may require future modules.
- We own the accounting and conceptual model, avoiding lock-in to a third-party platform's upgrade cadence.
- Feature additions must be validated against the narrow scope and deliberately small footprint.
