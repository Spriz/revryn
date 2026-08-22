# Production-readiness review v1 — evidence matrix

Status: **NO-GO** — three open gates remain (sandbox certification,
accountant sign-off, usability evidence); two gates were closed and two
deferred by owner decision on 2026-08-22 (rev 7): the signed CLI release
shipped and verified (`cli/v0.1.0`), the independent security review and
the full-scale capacity rerun are consciously postponed (see items 4/7).
Date: 2026-08-22 (rev 7) · Reviewed state: `main` pushed to
github.com/Spriz/revryn — **remote CI fully green** (run 32588941571: all
8 jobs — test+credo+dialyzer, Go CLI, 3 standalone showcases, fnox
config, official image with backup/restore, release-mode Playwright with
CLI/MCP live certification). Getting that run green surfaced and fixed
three real production defects the local evidence had missed: invitation
delivery crashed any release without SMTP configured (mail transport now
degrades to link-only), generated absolute URLs hardcoded https/443
(`PHX_URL_SCHEME`/`PHX_URL_PORT` added), and release evals inherited
`PHX_SERVER=true` (fixture forces `server: false`). Plus two test races
(Registry cleanup, LiveView dead-render fill).

This is the BC-TASK-076 evidence matrix. Each gate lists its current
verdict and the evidence trail. A gate is PASS only with retained,
re-runnable evidence; OPEN gates name the exact unblocking action and who
owns it. The companion gap audit
(`spec-gap-audit-2026-08-22.md`) records per-task detail; `TODO.md` is the
operational ledger.

## Verified gates (PASS, evidence retained)

| Gate | Evidence |
|------|----------|
| Deterministic domain suite | `mix precommit`: 750 tests incl. 16 properties, formatted, warnings-as-errors, dialyzer zero-warning, from an empty schema. |
| Static analysis | Credo enforced in CI; dialyxir with cached PLTs in precommit + CI (zero warnings; three documented false-positive suppressions). |
| Migration chain from scratch | CI + local: full chain migrates on empty dev/test/prod databases and inside the official image. |
| Production-release browser certification (SPEC §23.6) | CI job builds `MIX_ENV=prod` release with digested assets, migrates via `bin/billing_core eval`, boots, runs all Playwright suites against it; 10/10 specs locally, rerun-stable. |
| Official image build + boot (SPEC §24.6) | CI job + local run: all-in-one boots to green `/health/ready`, image smoke-test and doctor profiles pass. |
| Backup → restore → verify (SPEC §24.9) | Executed inside the image: archive with checksums, restore into a disposable database, integrity checks "verified". |
| First-run activation happy path + provider-failure recovery (BC-US-166) | Playwright: five-phase demo journey to a closed reconciled month, returning-user resume, induced provider outage remediated through the operations inbox. |
| Monthly close lifecycle incl. corrections (BC-US-163…165, ADR-031) | Workflow + browser + API tests: full lifecycle, zero-delta, outcome-unknown recovery, retry routing, reversal/replacement, prior-period approval, month-to-month continuity in-browser. |
| Credit subledger complete (BC-US-107…109) | Grants/reserve/apply/release/refund/expiry/disposition, §10.1 downgrade credits, termination disposition, ledger replay; receivable settlement (SPEC §9.4.1): certified mode gate blocks silent netting, exactly-once external-reference and ERP clearing-voucher reconciliation (`receivable_settlement_test.exs`). |
| Organizations-and-membership contract (SPEC §14.5, complete row) | Invitations (single-use, hashed), membership directories, role changes with last-owner/last-team protections, INV-024 team grants; GraphQL + LiveView + browser multi-membership scenario (INV-032). |
| Interface parity for shipped domains | LiveView, GraphQL (SDL artifact diffed in CI), revryn (goldens), MCP (schema/annotation tests) across closes, corrections, credits, settlements, memberships; cross-team denial tested per interface. |
| CLI/MCP live certification (BC-TASK-100) | `e2e/cli/run.sh` + `e2e/mcp/run.sh` against a live server with real auth; confirm-gate refusal proven; runs in CI against the booted release (`cli-mcp-v1.md`). |
| Async-failure remediation (BC-US-154…156) | Failure-inbox taxonomy (user-fixable/operator-only/non-retryable/automatic), support bundles, admin-gated remediation in the domain command; worker-declaration completeness table; crash-redelivery and pruning-survival proofs (`failure_matrix_test.exs`); four Playwright remediation scenarios. |
| Capacity engineering baseline (SPEC §21) | `capacity-v1.md`: 500-line preview 16.5 ms (obj. 5 s), ingest p95 0.3 ms (obj. 500 ms), ~3.3k events/s, 50 concurrent throttled ERP ops exactly-once, idempotent concurrent partitioning, 300-iteration soak with bounded memory; reproducible suites (`--only performance/soak`). |
| Retention + privacy (SPEC §20) | Table-complete classification with CI gate; allowlist pruning; team-configurable raw-usage retention (90-day floor, gated deletes, freeze boundary); customer erasure procedure with retained financial evidence (`customer_erasure_test.exs`). |
| Audit package export (BC-US-114) | Chain reconstruction with per-file SHA-256 manifest; auditor access; credential-absence test. |
| Lifecycle single-source proof (BC-US-160) | Five executable transition tables render the generated `docs/architecture/state-machines.md`; sync-tested. |
| Docs/contract consistency (BC-TASK-084) | `product-contract-consistency-v1.md`: 73/73 public GraphQL fields documented; traceability table; four artifact sync gates in CI. |
| Operability (BC-TASK-095) | `operability-phoenix-v1.md`: DB/queue/ERP/SMTP/backup/config diagnosis matrix on supported surfaces; doctor grew smtp+queue checks (seeded-failure tested, secret-leak regression); no unnecessary infrastructure. |
| Diff-scoped security review | `security-review-2026-08-22.md` (self-review; independent review still required below). |

## Open gates (NO-GO drivers)

**Blocked on inputs only the operator/owner can provide — each now
turnkey (the engineering side is prepared):**

1. **e-conomic sandbox certification.** One action:
   `fnox set ECONOMIC_SANDBOX_SECRET` (stores it age-encrypted in the
   committed `fnox.toml` — `docs/runbooks/secrets.md`), then
   `fnox exec -- mix run --no-start e2e/economic/certify.exs` — the harness
   runs preflight, capabilities, and the annual-prepaid draft/read-back
   cycle against the real sandbox and writes the evidence report.
   Owner: user.
2. **Accountant sign-off.** One action: hand
   `docs/reviews/accountant-review-pack.md` (reading order + sign-off
   checklist) to the accountant. Owner: user's accountant.
3. **Qualitative activation evidence.** One action: run 2–4 sessions per
   `docs/reviews/usability-protocol.md` (script, pass signals, evidence
   format); telemetry is already in place. Owner: user.
4. **Independent security review — DEFERRED by owner decision
   (2026-08-22).** The owner chose to skip the external review for now;
   the diff-scoped self-review (`security-review-2026-08-22.md`) and the
   prepared scoping pack (`security-review-scoping.md`) stand ready for
   when it is commissioned. Risk accepted by: user. Revisit before
   exposing the deployment to untrusted tenants or the public internet
   at scale.

**Implementable, not yet done (tracked with next actions in `TODO.md`):**

5. ~~Showcase program~~ — complete: all THREE showcases (Django, Rails,
   Laravel) are certified standalone AND integrated; each reconciles an
   intent to `erp_draft` against the fake adapter, and the Laravel run
   additionally certifies annual service-period propagation (365-day
   frozen line). PHP was unblocked without sudo via a source-built libgd.
6. ~~Signed CLI release artifacts/SBOM~~ — **CLOSED (2026-08-22)**: the
   user pushed `cli/v0.1.0`; the release workflow succeeded on its first
   run, publishing the 5-target `revryn` binary matrix, SHA256SUMS, SPDX
   SBOM, Sigstore bundles, and VERIFY.md. Independently verified:
   checksum match plus `cosign verify-blob` against the repository's
   GitHub OIDC identity → "Verified OK".
7. Full-scale §21.2 capacity rerun — **DEFERRED by owner decision
   (2026-08-22) until proof-of-concept / product-market fit.** The
   dev-machine baseline passed every §21.1 objective with 28×–300×
   headroom (`capacity-v1.md`), which the owner accepts as sufficient
   for the current stage. Turnkey when revisited: `CAPACITY_SCALE=100
   mix test --only performance` on production-like hardware. Risk
   accepted by: user.
8. ~~Flat-fee plan-component shape~~ — resolved: minimum-commit over a
   zero-rate inner is the contract's native flat fee; the CRM integration
   is recertified fully platform-priced, and the exercise fixed a real
   preview routing bug for minimum-commit components (regression test
   retained).

## Standing verification commands

```sh
mix precommit                                    # domain + format + warnings + dialyzer
(cd clients/revryn && go vet ./... && go test ./...)
(cd e2e && npx playwright test)                  # dev server; CI runs the release harness
BASE_URL=http://localhost:4000 e2e/cli/run.sh && e2e/mcp/run.sh
mix test --only performance                      # capacity evidence
docker build -f deploy/container/Dockerfile -t billing-core:ci .
```

## Verdict

Every engineering gate that can be closed on this machine now holds with
retained, re-runnable evidence — 19 PASS gates plus two certified showcase
integrations. Production go-live remains **blocked** on the four external
inputs above plus three environment/owner-blocked items (PHP for the
Laravel showcase, signing identity, production-scale hardware); no freely
implementable engineering remainder is known on this machine.
This document must be regenerated and re-dated at every subsequent review
until the verdict is GO.
