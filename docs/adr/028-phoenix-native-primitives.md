# ADR-028 — Phoenix-native scope and runtime primitives

Status: accepted
Date: 2026-08-21

## Context and decision

Use Phoenix 1.8 scoped data-access conventions, Bandit, PubSub, LiveDashboard, OTP supervision, Ecto, Req, Swoosh, and other small ecosystem primitives before introducing framework-neutral infrastructure.

## Consequences

- Additions such as Broadway, Kafka, Redis, service meshes, or alternate process orchestration require measured need and an ADR; they are not architecture defaults.
- The system stays within the Phoenix ecosystem and benefits from its maturity and integration.
- Operational footprint is kept small by avoiding unnecessary infrastructure.
