# ADR-015 — Full snapshot before external effect

Status: accepted
Date: 2026-08-21

## Context and decision

All calculation and mapping inputs are frozen in a snapshot before any synchronization with external systems (e.g., e-conomic). This snapshot captures the complete state at the moment of decision.

## Consequences

- Historical invoices remain reproducible even after catalog or customer changes.
- Auditing is simplified because the full calculation context is preserved with each invoice.
- Downstream systems can always trace which inputs produced which output.
