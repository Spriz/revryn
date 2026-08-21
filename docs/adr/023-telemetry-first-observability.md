# ADR-023 — Telemetry-first, vendor-neutral observability

Status: accepted
Date: 2026-08-21

## Context and decision

Use Elixir `:telemetry` as the internal instrumentation contract, structured JSON Logger output, secured Phoenix LiveDashboard, Prometheus-compatible metrics, and optional OpenTelemetry/OTLP export. The stock deployment is diagnosable without a proprietary APM agent.

## Consequences

- Monitoring-vendor code never enters the billing domain, avoiding lock-in and security risks.
- Observability is built on open standards and can be exported to any backend.
- The system remains observable and debuggable even without external monitoring services.
