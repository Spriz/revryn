# ADR-022 — Phoenix-native design system and Storybook

Status: accepted
Date: 2026-08-21

## Context and decision

Shared Phoenix components will be built and documented/rendered in Phoenix Storybook. JavaScript Storybook is unnecessary for the default architecture.

## Consequences

- Reusable UI components are designed once and consumed across LiveViews consistently.
- Component documentation and rendering stays within the Phoenix ecosystem.
- No separate frontend build system or JavaScript tooling is required for component development.
