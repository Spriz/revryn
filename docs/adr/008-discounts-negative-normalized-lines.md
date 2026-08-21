# ADR-008 — Discounts are negative normalized lines

Status: accepted
Date: 2026-08-21

## Context and decision

Percentage and fixed discounts will materialize as negative line items in invoices rather than being handled as separate discount structures. This normalizes the data model and provides a single deterministic representation.

## Consequences

- One unified model supports allocation, accrual periods, credits, and ERP portability.
- Line-based processing in downstream systems can handle discounts without special logic.
- Invoice line-item visibility and audit trails are simplified and consistent.
