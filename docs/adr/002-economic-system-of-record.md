# ADR-002 — e-conomic is the accounting system of record

Status: accepted
Date: 2026-08-21

## Context and decision

Booked invoices, VAT, accrual entries, payments, and accounting periods are authoritative in e-conomic. We treat e-conomic as the system of record for all accounting state and never claim that Billing Core's own data is the source of truth for revenue schedules or financial state.

## Consequences

- Billing Core stores immutable intent and evidence but defers to e-conomic for accounting authority.
- Synchronization logic must handle e-conomic as the authority and reconcile Billing Core state against it.
- Any discrepancies between Billing Core and e-conomic must be resolved by accepting e-conomic as correct.
