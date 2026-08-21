# ADR-010 — Stable invoice references and idempotent effects

Status: accepted
Date: 2026-08-21

## Context and decision

Each logical ERP document will have one stable external reference and operation keys that enable idempotency. This allows retries and unknown outcomes to be resolved by lookup and reconciliation rather than creating duplicate documents.

## Consequences

- Retries of failed operations do not create duplicate invoices or entries in e-conomic.
- Idempotency keys allow safe retry logic and recovery from transient failures.
- Reconciliation can match Billing Core documents to e-conomic by stable reference.
