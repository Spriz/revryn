# ADR-006 — Half-open service periods

Status: accepted
Date: 2026-08-21

## Context and decision

All domain intervals use the half-open interval notation `[start, end)`, where start is inclusive and end is exclusive. This provides a consistent model for time periods throughout the system.

## Consequences

- Adapter conversion to inclusive ERP dates (which e-conomic may require) is centralized and tested in one place.
- Adjacent periods have no overlap and no gaps when using half-open intervals.
- Period logic is consistently expressed and easy to reason about across the codebase.
