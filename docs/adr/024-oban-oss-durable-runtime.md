# ADR-024 — Oban OSS is the normative durable worker runtime

Status: accepted
Date: 2026-08-21

## Context and decision

Use Apache-2.0 Oban OSS on PostgreSQL for background work, scheduling, retries, queue control, and job telemetry. Keep the transactional outbox for atomic business-event publication. Do not build a custom job framework or add Redis merely for jobs.

## Consequences

- Oban Pro may be evaluated later as an optional operator convenience but no correctness requirement depends on it.
- All job processing remains within the PostgreSQL/Elixir runtime.
- Job retry and failure handling is built into Oban and well-tested across the community.
