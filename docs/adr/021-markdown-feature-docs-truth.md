# ADR-021 — Markdown feature docs are the product source of truth

Status: accepted
Date: 2026-08-21

## Context and decision

Canonical feature behavior lives in `docs/features/*.md`. Implementation, tests, GraphQL schema, and marketing derive from or link back to those documents. External contributors can agree on behavior before code.

## Consequences

- Feature behavior is reviewable and discussable as text before implementation.
- Product promises are explicit and verifiable as documentation.
- All implementation changes must be reflected in or justified against the feature docs.
