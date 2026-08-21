# ADR-019 — One official OCI image, including all-in-one profile

Status: accepted
Date: 2026-08-21

## Context and decision

Ship one OCI image that supports both a self-contained `all-in-one` role with supervised PostgreSQL and split roles with external PostgreSQL. Do not create separate packaging architectures for different deployment models.

## Consequences

- Self-hosting remains simple without requiring multiple image variants.
- Bundled PostgreSQL lifecycle and upgrade safety become product responsibilities.
- The single image reduces build and maintenance complexity.
