# ADR-017 — Playwright is mandatory feature evidence

Status: accepted
Date: 2026-08-21

## Context and decision

Every user-visible P0 workflow is exercised end-to-end with Playwright against a built release. Browser tests are treated as core regression and workflow-documentation assets rather than optional UI tests.

## Consequences

- Browser tests are slower than unit tests but provide high-confidence evidence of feature completeness.
- Playwright tests serve as executable documentation of supported user workflows.
- Workflow changes require corresponding Playwright test updates, keeping documentation in sync with behavior.
