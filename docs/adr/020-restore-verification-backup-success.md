# ADR-020 — Restore verification defines backup success

Status: accepted
Date: 2026-08-21

## Context and decision

A backup is considered recovery-verified only after a clean restore and smoke/integrity test suite succeeds. Backup creation and restore verification are tracked independently in release CI and production operations.

## Consequences

- Backup completeness is validated by actual restore testing, not by backup log inspection alone.
- Release CI and production operations track restore verification as a separate operational concern.
- Failed restores are detected and reported before they become production emergencies.
