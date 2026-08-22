# Runbook: deploy and operate the Revryn release

Scope: booting, configuring, migrating, health-checking, and verifying the
compiled production release (SPEC §12.2.2, §21, §22.6, §23.6). The container
build lives in `deploy/container/`; backup/restore tooling in `scripts/`.

## Release environment contract

Required (secret-bearing variables also accept the `<NAME>_FILE`
indirection — a path to a mounted secret file; see
`docs/runbooks/secrets.md`):

| Variable | Meaning |
|----------|---------|
| `DATABASE_URL` | `ecto://user:pass@host:port/db` — PostgreSQL is the authority for all durable state. |
| `SECRET_KEY_BASE` | ≥64 bytes; generate with `mix phx.gen.secret`. Rotating it invalidates sessions. |
| `PHX_HOST` | Public hostname; drives generated URLs and the WebAuthn defaults below. |
| `PHX_SERVER` | `true` to serve HTTP (the migrate/eval commands run without it). |

Optional / situational:

| Variable | Meaning |
|----------|---------|
| `PORT` | HTTP port (default 4000). |
| `PHX_URL_SCHEME` / `PHX_URL_PORT` | Scheme/port for *generated* absolute URLs (invitation links, mail). Default `https`/443 — override only when the public origin is plain HTTP or a nonstandard port. |
| `POOL_SIZE` | Database pool size. |
| `WEBAUTHN_ORIGIN` | Exact browser origin for passkeys (default `https://$PHX_HOST`). Must match scheme+host+port the user's browser sees, or registration/sign-in fails attestation. |
| `WEBAUTHN_RP_ID` | Relying-party ID (default `$PHX_HOST`). |
| `PHX_CHECK_ORIGIN` | Comma-separated allowed websocket origins. Unset = framework default (must match the configured url). The release-based browser certification sets `http://localhost:4000`; `false` is for isolated labs only. |
| `REVRYN_DEMO_ERP_ENABLED` | `true` opts a deployment into guided demo workspaces (single-node only). |
| `CREDENTIAL_CIPHER_KEY` | Key for ERP credential encryption at rest. |
| `RESTORE_VALIDATION_MODE` | `true`/`1` hard-disables real ERP writes while a restored deployment is verified (§23.9). Workers defer provider writes. |
| `RELEASE_DISTRIBUTION` | Set `none` when running without Erlang distribution (e.g. a second instance on one host for certification). |

## Boot procedure

```sh
bin/billing_core eval "BillingCore.Release.migrate()"   # idempotent
bin/billing_core eval "BillingCore.Release.doctor()"    # redacted config/dependency checks
PHX_SERVER=true bin/billing_core daemon                  # or `start` in the foreground
curl -fsS http://localhost:$PORT/health/ready            # {"status":"ok","checks":{...}}
```

`/health/live` answers as soon as the VM serves HTTP; `/health/ready` also
verifies the database connection, migration currency, and Oban queues — gate
load-balancer traffic on `ready`.

## Upgrades

1. Deploy the new image/release alongside the old one (do not stop the old).
2. Run `Release.migrate()` — migrations are additive and lock-safe.
3. Health-check the new instance, shift traffic, stop the old release.
4. Rollback = redeploy the previous image. Never roll back migrations on a
   shared database; use `Release.rollback(repo, version)` only in isolated
   recovery scenarios.

## Backup, restore, and restore validation

- `scripts/backup` — logical dump of the authoritative PostgreSQL database.
- `scripts/restore` — restores a dump into a target database.
- `scripts/restore-verify` — boots a release against the restored copy with
  `RESTORE_VALIDATION_MODE=true` so no real ERP write can occur, then runs
  the health and reconciliation checks.

A restored deployment must keep `RESTORE_VALIDATION_MODE=true` until
finance confirms reconciliation against e-conomic — the mode makes stale
duplicate provider writes impossible while evidence is compared.

## Browser certification against the release (SPEC §23.6)

CI's `Playwright E2E (production release)` job is the reference harness:
build (`mix assets.deploy && MIX_ENV=prod mix release`), migrate through the
release binary, boot with `PHX_CHECK_ORIGIN`/`WEBAUTHN_ORIGIN` pointing at
`http://localhost:4000`, then run `PW_BASE_URL=http://localhost:4000 npx
playwright test` from `e2e/`. Locally the same sequence works on any port;
without `PW_BASE_URL` the suites fall back to the dev server for iteration.

## Failure triage entry points

- Boot loops with database errors → check `DATABASE_URL`, run `doctor()`.
- Readiness reports every migration pending although `Release.migrate()`
  succeeded → a schema named after the database role shadows unqualified
  tables via PostgreSQL's `"$user"` search_path entry (the official image's
  role `billing` collides with the `billing` schema). The application pins
  `migration_default_prefix: "public"` precisely to defuse this; if you see
  it, the deployment runs a build predating that pin — upgrade, and never
  hand-delete either `schema_migrations` table.
- Passkey registration fails with an attestation error → `WEBAUTHN_ORIGIN`
  does not match the browser origin exactly.
- LiveView pages load but interactions do nothing → websocket rejected;
  check `PHX_CHECK_ORIGIN` against the browser origin.
- ERP effects stuck → operations inbox in the product first (§22.9.3;
  failed operations carry safe error detail and a retry), then Oban state
  via LiveDashboard (`/admin/dashboard`, platform administrators only).
- Provider mismatch on a posted close → never edit; follow the correction
  runbook in `docs/accounting/customer-credit-close.md` (ADR-031).

## Alerts

`deploy/observability/alerts.yml` is the reference Prometheus rule pack:
availability (exporter up, HTTP 5xx vs the §21.1 objective), queue health
(Oban error rate), durable-operation dead-letter/block transitions (the
"open the operations inbox" signal), outbox stall, and BEAM memory vs the
capacity baseline. Wire it into your Prometheus and tune thresholds before
go-live; every alert names its runbook.
