# ADR-014 — Provider webhooks are hints

Status: accepted
Date: 2026-08-21

## Context and decision

Every webhook-triggered state change requires an authoritative provider read. Webhooks from external providers (like e-conomic) are treated as hints that trigger reconciliation, not as authoritative state updates.

## Consequences

- Webhook handlers never accept provider state as truth; they fetch fresh state from the provider to confirm.
- The system is resilient to webhook loss, duplication, and reordering.
- Reconciliation and verification are integral to the sync workflow rather than optional.
