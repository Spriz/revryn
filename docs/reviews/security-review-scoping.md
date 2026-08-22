# Independent security review — scoping pack (release gate 4)

For the external reviewer. The release gate requires a review not
authored by the implementer; this pack is the hand-off.

## System in one paragraph

Phoenix modular monolith (`lib/billing_core*`), PostgreSQL-authoritative,
passkey-first auth (WebAuthn + recovery codes + TOTP), team-scoped
authorization via `BillingCore.Scope` resolved server-side on every
request (INV-024/025), public GraphQL at `/graphql` (Absinthe, typed
unions, complexity caps), Go CLI/MCP clients over the same contract, Oban
background work with a transactional outbox, e-conomic ERP adapter with
secrets resolved by reference from env.

## Entry points

| Surface | Code | Notes |
|---|---|---|
| Browser (LiveView) | `lib/billing_core_web/live/` | session auth, CSRF, team scope on mount |
| GraphQL | `lib/billing_core_web/graphql/` | bearer sessions, RequireScope middleware, SafeResolution sanitization |
| Webhooks | ERP webhook token (hashed at rest) | untrusted-hint model: payloads never trusted, authoritative re-read |
| CLI/MCP | `clients/revryn/` | bearer token; MCP confirm-gates all mutations |
| Release/image ops | `deploy/container/` | doctor/backup/restore roles |

## Crown jewels and invariants to attack

- Financial evidence immutability (DB triggers: append-only tables,
  gated raw-usage delete, settlement terminality)
- Cross-team isolation (INV-024: possession of an ID must never grant
  access — every list/get is scope-filtered)
- Idempotency/exactly-once of external effects (operation keys,
  find-before-create, outcome-unknown reconciliation)
- Secrets: never in Oban args, logs, exports (tests enforce); tokens
  hashed at rest; doctor output redaction
- Last-owner/last-team lockout protections

## Prior work to verify, not repeat

`docs/reviews/security-review-2026-08-22.md` (implementer self-review),
`product-contract-consistency-v1.md`, `operability-phoenix-v1.md`.
Suggested depth: the §23 resilience/security test list (SPEC line 4406)
is the checklist the suite claims to cover — sample and adversarially
verify rather than re-derive.

## How to run everything

`README.md` quick start; `mix precommit`; e2e suites in `e2e/`;
seeded-failure drills in the demo workspace. A disposable environment is
one `docker run` of the official image (all-in-one role).
