# ADR-016 — Phoenix LiveView instead of a SPA

Status: accepted
Date: 2026-08-21

## Context and decision

Phoenix LiveView/HEEx will be used for all human-facing product surfaces instead of a standalone Single-Page Application (SPA). e-conomic remains a provider-native REST integration behind its adapter, and browser JavaScript is progressive enhancement only.

## Consequences

- UI and domain code ship in one Phoenix release, reducing deployment complexity.
- LiveView must not become a place for domain logic; business rules stay in the application layer.
- Browser interactivity is handled through LiveView sockets, not a separate frontend framework.
