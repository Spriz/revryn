# ADR-012 — GraphQL-first public application API

Status: accepted
Date: 2026-08-21

## Context and decision

The general-purpose public machine application API will be exposed through Absinthe GraphQL. LiveView uses domain contexts directly. e-conomic remains a provider-native REST integration behind its adapter. MCP is a separate semantic agent interface and is not a generic replacement REST API.

## Consequences

- Schema evolution is additive and deprecation-driven rather than URL-version driven.
- Complexity limits, cursor pagination, batching, authorization, schema diffing, and typed mutation semantics are mandatory platform capabilities.
- LiveView and CLI/MCP tools have distinct API contracts optimized for their use cases rather than sharing a generic REST layer.
