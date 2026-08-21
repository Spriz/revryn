# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the Billing Core project. Each ADR documents a significant architectural decision, its rationale, and consequences.

## Index

| # | Title | File | Summary |
|---|-------|------|---------|
| 001 | Build a small billing core rather than fork Lago | [001-build-small-billing-core.md](001-build-small-billing-core.md) | Implement only required pricing and invoice capabilities rather than forking a broad platform. |
| 002 | e-conomic is the accounting system of record | [002-economic-system-of-record.md](002-economic-system-of-record.md) | e-conomic is authoritative for invoices, VAT, accrual, payments, and accounting periods. |
| 003 | Modular monolith with separate workers | [003-modular-monolith-separate-workers.md](003-modular-monolith-separate-workers.md) | Single codebase/database deployed as API, worker, and admin processes. |
| 004 | PostgreSQL outbox and durable jobs | [004-postgresql-outbox-durable-jobs.md](004-postgresql-outbox-durable-jobs.md) | PostgreSQL provides transactional outbox and job leasing; no external broker required. |
| 005 | Minor units plus arbitrary-precision decimals | [005-minor-units-arbitrary-precision.md](005-minor-units-arbitrary-precision.md) | Final money as signed integers; rates and quantities use decimal strings. |
| 006 | Half-open service periods | [006-half-open-service-periods.md](006-half-open-service-periods.md) | All intervals use `[start, end)` notation for consistent period handling. |
| 007 | Booked documents are immutable | [007-booked-documents-immutable.md](007-booked-documents-immutable.md) | Post-booking changes use credits and replacements; no direct mutation. |
| 008 | Discounts are negative normalized lines | [008-discounts-negative-normalized-lines.md](008-discounts-negative-normalized-lines.md) | Percentage and fixed discounts materialize as negative line items. |
| 009 | Draft-first; manual booking by default | [009-draft-first-manual-booking.md](009-draft-first-manual-booking.md) | Invoices start in draft; booking requires finance approval by default. |
| 010 | Stable invoice references and idempotent effects | [010-stable-references-idempotent-effects.md](010-stable-references-idempotent-effects.md) | Each ERP document has one stable reference; operations are idempotent. |
| 011 | Multi-team data model, one legal entity per team | [011-multi-team-data-model.md](011-multi-team-data-model.md) | All data is team-scoped; each team maps to one legal entity in v1. |
| 012 | GraphQL-first public application API | [012-graphql-first-public-api.md](012-graphql-first-public-api.md) | Public API exposed via Absinthe GraphQL; LiveView uses domain contexts directly. |
| 013 | Apache-2.0 | [013-apache-license.md](013-apache-license.md) | License project and official adapters under Apache License 2.0. |
| 014 | Provider webhooks are hints | [014-provider-webhooks-hints.md](014-provider-webhooks-hints.md) | Webhook-triggered changes require authoritative provider read to confirm. |
| 015 | Full snapshot before external effect | [015-full-snapshot-external-effect.md](015-full-snapshot-external-effect.md) | Freeze all inputs before synchronization; historical invoices remain reproducible. |
| 016 | Phoenix LiveView instead of a SPA | [016-phoenix-liveview-not-spa.md](016-phoenix-liveview-not-spa.md) | Use Phoenix LiveView/HEEx for human-facing surfaces; avoid standalone SPA. |
| 017 | Playwright is mandatory feature evidence | [017-playwright-mandatory-feature-evidence.md](017-playwright-mandatory-feature-evidence.md) | Every P0 user workflow is tested end-to-end with Playwright. |
| 018 | Integration tests are first-class workflow documentation | [018-integration-tests-first-class.md](018-integration-tests-first-class.md) | Favor workflow-level integration tests over mock-heavy unit testing. |
| 019 | One official OCI image, including all-in-one profile | [019-one-oci-image-all-in-one.md](019-one-oci-image-all-in-one.md) | Ship one image supporting both all-in-one and split deployment modes. |
| 020 | Restore verification defines backup success | [020-restore-verification-backup-success.md](020-restore-verification-backup-success.md) | Backup success is verified only after clean restore and smoke tests. |
| 021 | Markdown feature docs are the product source of truth | [021-markdown-feature-docs-truth.md](021-markdown-feature-docs-truth.md) | Canonical behavior lives in `docs/features/*.md`; implementation derives from it. |
| 022 | Phoenix-native design system and Storybook | [022-phoenix-native-design-storybook.md](022-phoenix-native-design-storybook.md) | Build and document Phoenix components in Phoenix Storybook; no JavaScript Storybook. |
| 023 | Telemetry-first, vendor-neutral observability | [023-telemetry-first-observability.md](023-telemetry-first-observability.md) | Use Elixir telemetry, JSON logs, and optional OTLP; no proprietary APM agents. |
| 024 | Oban OSS is the normative durable worker runtime | [024-oban-oss-durable-runtime.md](024-oban-oss-durable-runtime.md) | Use Oban OSS on PostgreSQL for jobs; no custom framework or Redis for job queueing. |
| 025 | Durable operations are distinct from queue jobs | [025-durable-ops-distinct-queue.md](025-durable-ops-distinct-queue.md) | Operation state is persisted in domain tables, linked to but independent from Oban. |
| 026 | Go is the implementation language for `billingctl` and MCP | [026-go-billingctl-mcp.md](026-go-billingctl-mcp.md) | CLI and MCP implemented in Go; Phoenix remains the domain runtime. |
| 027 | MCP exposes semantic tools, not arbitrary GraphQL | [027-mcp-semantic-tools.md](027-mcp-semantic-tools.md) | MCP tools model workflows; no raw GraphQL, SQL, or shell access. |
| 028 | Phoenix-native scope and runtime primitives | [028-phoenix-native-primitives.md](028-phoenix-native-primitives.md) | Use Phoenix 1.8 primitives before introducing external infrastructure. |
| 029 | Explicit transactional state machines for non-trivial lifecycles | [029-transactional-state-machines.md](029-transactional-state-machines.md) | Model complex lifecycles as explicit state machines; PostgreSQL remains authoritative. |
| 030 | Transactional domain events, not event sourcing, for v1 | [030-transactional-domain-events.md](030-transactional-domain-events.md) | Use transactional outbox for events; event sourcing deferred to future ADR. |
