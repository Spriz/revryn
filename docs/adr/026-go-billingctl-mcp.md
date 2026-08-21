# ADR-026 — Go is the implementation language for `billingctl` and MCP

Status: accepted
Date: 2026-08-21

## Context and decision

Implement the public CLI in Go with Cobra and implement MCP in the same Go module using the official Tier-1 MCP Go SDK. Package `billingctl` in the official OCI image and publish native binaries separately. Phoenix remains the application/domain runtime.

## Consequences

- Go is a deliberately small companion client/runtime for distribution-heavy interfaces, not the domain layer.
- CLI/MCP do not connect directly to PostgreSQL or bypass Phoenix authorization.
- Binary distribution and cross-platform support are simplified through Go's toolchain.
