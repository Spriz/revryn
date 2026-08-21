# ADR-025 — Durable operations are distinct from queue jobs

Status: accepted
Date: 2026-08-21

## Context and decision

User and business-significant asynchronous operation state is persisted in Billing Core domain tables and linked to Oban job execution attempts. Queue rows are not the system of record for failure history or remediation.

## Consequences

- Worker retry/pruning policies can change without losing user-visible operation state.
- The web UI, GraphQL, CLI, and MCP all expose the same operation lifecycle independently of job queue state.
- Operations remain visible to users even if the underlying job is pruned or removed.
