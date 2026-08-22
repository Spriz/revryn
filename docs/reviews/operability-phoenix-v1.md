# Operability and Phoenix-idiom review v1 (BC-TASK-095)

Date: 2026-08-22. Verdict: **pass for the engineering scope** — every
named failure family has a supported diagnosis surface requiring neither
SQL nor IEx; the Phoenix/OTP shape carries no unnecessary infrastructure.

## Diagnosis matrix (acceptance: seeded failures, supported surfaces only)

| Family | Seeded how | Supported surface | Evidence |
|---|---|---|---|
| Database | stop/point away PostgreSQL | `/health/ready` (fails with db detail), doctor `database`/`migrations` | image CI boots to ready; readiness caught the search_path incident |
| Queue | discarded/retryable Oban job | doctor `queues` (per-state counts, warn on dead work), operations inbox for domain work | `test/operability/diagnosis_test.exs` |
| ERP | FakeERP fault injection (4 classes) | operations inbox: class, safe cause, correlation, retry-safety, support bundle; demo failure drills | `operations_live_test.exs`, `e2e/features/operations_inbox.spec.ts` |
| SMTP | missing relay config | doctor `smtp` (named missing key), `docs/runbooks/smtp.md` | `diagnosis_test.exs` |
| Backup | restore into empty database | image CI backup→restore→verify cycle; `erp_writes_disabled` restore-validation mode defers ERP writes | ci.yml image job |
| Configuration | missing/short SECRET_KEY_BASE, pending migrations, clock drift | doctor checks with redacted details | `diagnosis_test.exs` (secret-leak regression) |

Doctor output is redacted (connection URLs and secrets scrubbed) and
available as text or JSON from the release binary and the container
`doctor` role — no application code paths required.

## Correlation evidence

One correlation id flows request → scope → operation → sync attempt →
audit fact → outbox event → CLI/MCP error strings (`[correlation-id: …]`)
and the inbox support bundle. Logs are structured (logger_json in prod)
with request ids; Prometheus exposes HTTP, repo, Oban, operation
transition, outbox, and BEAM families (`BillingCore.Metrics`, §22.3).

## Alert-to-runbook

`docs/runbooks/deploy-and-operate.md` (env contract, roles, health,
backup/restore, incident basics) and `docs/runbooks/smtp.md`; the
capacity review documents queue sizing. Gap: no alert-rule pack ships yet
(Prometheus rules are deployment-specific); the metric families and
thresholds are named in the runbook for the operator to wire.

## Phoenix/OTP idiom and unnecessary-infrastructure report

- Modular monolith at the root; LiveView-first UI calling domain contexts
  in-process; GraphQL only for external integrators — no internal HTTP
  hops, no SPA, no REST duplicate.
- Durable work: Oban on PostgreSQL with a transactional outbox — no
  Redis, no external broker, no cron host; the single Cron plugin is the
  only scheduler.
- State: PostgreSQL is the sole authority (INV-047); processes are
  restartable at any point — proven by the crash-redelivery and
  drain-based tests; ETS appears nowhere as an accounting store.
- Supervision: one application tree; FakeERP demo instances run under a
  DynamicSupervisor keyed by connection, isolated per workspace.
- No unnecessary infrastructure found; the two deliberate extras
  (Prometheus exporter, logger_json) are operability, not architecture.

## Clean-install review

The official image's all-in-one role boots migrate→ready on an empty
database (CI-proven each run); first-run offers the guided demo (Playwright
journey) or real workspace creation; `smoke-test` and `doctor` roles give
the operator a first-five-minutes check sequence.

## Follow-ups (resolved)

1. ~~Ship a reference Prometheus alert-rule pack~~ — shipped:
   `deploy/observability/alerts.yml`, linked from the runbook (exporter
   up, 5xx vs §21.1, Oban errors, operation dead-letter/block transitions,
   outbox stall, BEAM memory vs baseline).
2. Notification-delivery dead letters: **deliberately surfaced through
   the doctor's `queues` check (discarded counts) and logs, not the
   per-team operations inbox** — delivery jobs are addressee-scoped, not
   team-scoped, so an inbox listing would leak cross-team addresses.
   Domain effects are never coupled to notification delivery.
