# ADR-005 — Minor units plus arbitrary-precision decimals

Status: accepted
Date: 2026-08-21

## Context and decision

We will use signed minor-unit integers for final money values (e.g., cents, pence), while rates, quantities, and intermediate calculations use decimal strings or arbitrary-precision arithmetic. Binary floating point is explicitly prohibited for domain money.

## Consequences

- All final money amounts are represented as exact integers, eliminating floating-point rounding errors in accounting.
- Rates and quantities use decimal strings to maintain precision during calculations and conversions.
- Audit trails and reconciliation remain deterministic and verifiable across systems.
