# ADR-027 — MCP exposes semantic tools, not arbitrary GraphQL

Status: accepted
Date: 2026-08-21

## Context and decision

MCP tool names and schemas model supported billing workflows and diagnostics. Do not expose raw GraphQL execution, SQL, shell, or internal process access through MCP. Agents get a stable task-oriented contract with narrower authority.

## Consequences

- Agent consumers have clearer side-effect semantics and safer confirmation/idempotency behavior than arbitrary query generation.
- The MCP schema remains stable and workflow-focused, not exposing implementation details.
- Authorization and rate-limiting are enforced at the semantic tool level.
