# Revryn

An accrual-aware, open-source billing core for B2B SaaS: it owns pricing
calculation, deterministic invoice intent, and idempotent synchronization to
[e-conomic](https://www.e-conomic.dk) as the accounting system of record.
Built per [SPEC.md](SPEC.md) — the normative product and architecture
reference.

**Billing Core is not** a payment processor, general ledger, tax engine, or
revenue-recognition engine. It calculates what should be invoiced and sends
the accounting facts (including line-level service periods for accruals) to
the ERP, then reconciles what the ERP actually recorded.

## What works today

- **Domain kernel** — integer minor-unit money with half-away-from-zero
  rounding and largest-remainder allocation; half-open date periods with
  anchor-day month math; canonical JSON + SHA-256 snapshot hashing;
  transition-table state machines with Mermaid export.
- **Pricing engine** — fixed recurring, one-time, standard metered,
  volume-tier, graduated-tier, package, and minimum-commit models with exact
  decimal arithmetic, full calculation traces, and property-tested proration
  and discount allocation.
- **Multi-tenant identity** — organizations with teams as the hard isolation
  boundary, membership-local roles, scope-resolved authorization, passkey
  (WebAuthn) + TOTP + recovery-code authentication.
- **Catalog** — products with recognition policies, immutable published plan
  versions, price components validated against the pricing schema, discounts
  and assignments, ERP product mappings.
- **Contracts** — versioned customers, contracts, subscriptions with
  overlap-protected version history, quantity/plan changes, cancellation
  policies, one-time charge instances.
- **Usage** — partitioned, immutable usage events with idempotent ingestion,
  void/replacement corrections, and cutoff-reproducible aggregation
  (sum/count/max/unique-count) in the team's time zone.
- **Billing** — scheduled runs with double-billing occurrence guards,
  per-customer consolidation, deterministic previews (fixed + metered +
  discounts + automatic customer-credit application), immutable invoice
  intents with database-enforced append-only lines.
- **Customer credit** — append-only currency-scoped credit ledger with
  earliest-expiry allocation, reservations, refunds, expiry scheduling, and
  loud-failure balance reconciliation.
- **ERP synchronization** — adapter port with a stateful fake ERP and a real
  e-conomic REST adapter; durable operations with classified retry policy;
  read-after-write reconciliation with fatal/warning severity; approval and
  booking flows; unknown-outcome recovery; human-edit detection; external
  booking observation via webhook hints + polling.
- **Corrections** — full and partial compensating credit notes with
  cumulative bounds and correction cases; booked documents are never mutated.
- **Interfaces** — GraphQL API (`/graphql`) with typed mutation results,
  idempotency, and scope-checked resolvers; Phoenix LiveView surfaces;
  health endpoints; append-only audit log and transactional outbox.
- **`revryn`** — cross-platform Go CLI over the GraphQL contract with
  stable `--json` envelopes, a registered exit-code taxonomy, retry/backoff,
  and correlation IDs; plus `revryn mcp serve`, an MCP server exposing
  14 semantic billing tools (read-only + confirm-gated mutations — never
  arbitrary GraphQL/SQL). Build from `clients/revryn/` with
  `CGO_ENABLED=0 go build ./cmd/revryn`.

## Getting started (development)

Requirements: Elixir 1.20/OTP 29 (via [mise](https://mise.jdx.dev)), Docker.

```bash
# Toolchain + database
mise install
docker run -d --name revryn-postgres -e POSTGRES_PASSWORD=postgres \
  -p 55432:5432 postgres:16-alpine

mix setup          # deps, database, migrations
mix test           # full suite
mix phx.server     # http://localhost:4000
```

End-to-end tests (Playwright): `cd e2e && npm install && npx playwright test`.

## Deployment

One OCI image serves every role (SPEC §24.6):

```bash
docker build -f deploy/container/Dockerfile -t billing-core .
docker run -v billing_data:/data -p 4000:4000 billing-core all-in-one
```

Roles: `all-in-one` (bundled PostgreSQL + web + workers), `web`, `worker`,
`migrate`, `doctor`, `backup --destination …`, `restore --source …`,
`smoke-test`. A backup is trusted only after `billing-core-restore-verify`
restores it into a disposable database and passes integrity checks
(INV-019).

## Repository layout

Per SPEC §24.1: the Phoenix modular monolith stays at the repository root,
with domain contexts in `lib/billing_core/`, web/GraphQL in
`lib/billing_core_web/`, workflow tests in `test/workflows/`, Playwright in
`e2e/`, feature docs in `docs/features/`, generated lifecycle diagrams in
[`docs/architecture/state-machines.md`](docs/architecture/state-machines.md),
and ADRs in `docs/adr/`. The Go CLI/MCP companion is an isolated module
under [`clients/revryn/`](clients/revryn/README.md). Secrets live
age-encrypted in the committed [`fnox.toml`](fnox.toml)
([runbook](docs/runbooks/secrets.md)). The marketing/documentation site is
an Astro project under [`site/`](site/), deployed to GitHub Pages by
`.github/workflows/site.yml`; it renders the `public: true` feature docs
and a GraphQL reference generated from `schema/billing_core.graphql`.

## License

Apache-2.0 — see [LICENSE](LICENSE).
