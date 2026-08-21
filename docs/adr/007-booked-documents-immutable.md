# ADR-007 — Booked documents are immutable

Status: accepted
Date: 2026-08-21

## Context and decision

Once an e-conomic invoice is booked, it must not be mutated directly. Any post-booking changes are handled through credits and replacement invoices, following accounting best practices.

## Consequences

- No code path attempts to mutate a booked e-conomic invoice; such operations are prevented by contract.
- Corrections and adjustments are explicit and traceable through the credit and replacement workflow.
- Audit trails remain clear and compliant with accounting principles.
