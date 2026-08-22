# Revryn implementation ledger

This is the resumable execution ledger for work defined in `SPEC.md`. The SPEC
is normative; this file records current implementation state and handoff
evidence. An ID is `done` only when all of its SPEC acceptance criteria are
satisfied. Missing IDs have not been audited and must not be assumed complete.

## Repository-wide audit snapshot — 2026-08-22

The prior recovery ledger covered only five of the 69 real task entries in the
SPEC work plan. The repository-wide audit now accounts for every task ID below.
Detailed evidence, feature gaps, and the recommended execution order are in
[`docs/reviews/spec-gap-audit-2026-08-22.md`](docs/reviews/spec-gap-audit-2026-08-22.md).

Audit conclusion (superseded 2026-08-22, end of day): the machine-local
engineering scope is complete — see
`docs/reviews/production-readiness-v1.md` (rev 5) for the authoritative
gate matrix: 19 platform PASS gates, all three showcases certified
standalone and integrated, and six remaining single-action items that
only the operator can take (credentials, accountant, users, external
reviewer, release tag, production hardware). Checked entries below carry
their evidence; the original morning audit text is retained in the gap
audit for history.

## Agent protocol

1. Read `AGENTS.md`, this ledger, and the relevant SPEC stories, task,
   invariants, feature docs, accounting notes, and ADRs before editing.
2. Put the task ID under **Doing** before changing it. State the narrow slice
   when the full task is larger than the current session.
3. Keep checklist items and verification commands current while working.
4. On handoff, record the exact next action, known risk, and dirty/staged state.
5. Move an ID to **Done** only after its complete acceptance criteria pass.

## Doing

### BC-TASK-103 — Monthly customer-credit close and e-conomic voucher

Current slice: deterministic close generation, evidence, aggregate voucher,
attachment, recovery, and reconciliation.

- [x] Close policy, lifecycle, movements, immutable membership, approvals, and evidence schemas.
- [x] Exact integer/Decimal close calculation and deterministic JSON/CSV/PDF/manifest bundle.
- [x] e-conomic and FakeERP finance-voucher/attachment adapter boundaries.
- [x] Durable posting, search-before-create, outcome-unknown recovery, and read-back reconciliation.
- [x] Focused unit and workflow tests, including cross-team denial and PostgreSQL immutability guards.
- [x] Run the full suite and `mix precommit` after all active changes settle.
- [ ] Sandbox-certify e-conomic multipart attachment field semantics.
- [x] Reversal/replacement correction path (ADR-031): `request_reversal/3`
  freezes a compensating mirrored-bridge close; its reconciled voucher
  terminally reverses the original; `generate_replacement/3` reproduces the
  exact frozen figures (membership-recomputed, hash-verified) under a
  corrected policy; continuity resolves through the replacement and blocks
  on a reversed period without one; partial period-uniqueness index +
  `close_kind` migration; LiveView remediation forms; workflow + LiveView
  coverage.
- [x] Late/prior-period paths: legally-late transactions (occurred after
  the prior cutoff) auto-classify as `prior_period_adjustment` in the next
  close (already unit-tested); a *missed* transaction (occurred at or
  before the accepted cutoff) blocks generation and is now routable via
  `generate(..., approved_prior_period_transaction_ids: [...])` — an
  explicit, audited approval that classifies it as a current-period
  prior-period adjustment (workflow-tested with a simulated commit race).

Next action: sandbox-certify the e-conomic voucher attachment and the
close/voucher field semantics — blocked on real e-conomic sandbox
credentials, which only the user can provide.

### BC-TASK-098 / BC-TASK-099 — Go CLI/MCP repository-boundary correction

Current slice: isolate the existing Go companion from the Phoenix root. This
does not claim that every CLI/MCP acceptance criterion is complete.

- [x] Move the Go module, CLI, MCP server, and contracts to `clients/revryn/`.
- [x] Update module imports, CI working directory, repository docs, and SPEC-owned paths.
- [x] Run `gofmt`, `go vet ./...`, `go build ./...`, and `go test ./...` from the module directory.
- [x] Search for stale root-level Go paths and repair compatibility links/docs.

Next action: continue the task-wide CLI/MCP acceptance audit from the isolated
module; the repository-boundary slice is staged with rename detection and
verified, but does not promote either full task to `Done`.

### BC-TASK-104 — Customer-credit close product surfaces and certification

Current slice: the LiveView close workflow over the shared domain commands.

- [x] Team-scoped close read APIs on `BillingCore.Credits.CloseWorkflow`
  (`list_closes/2`, `list_policies/1`, `list_movements/2`,
  `list_evidence_meta/2`, `latest_approval/2`, `posting_status/2`) shared by
  every adapter surface.
- [x] `/teams/:team_id/credit-closes` index: policy setup, deterministic
  generation with first-close bootstrap opening, and close listing.
- [x] Close detail page: review, exact-hash approval, durable posting,
  posting/outcome-unknown live refresh, reconciliation evidence, period
  acceptance, and remediation routing to the operations inbox.
- [x] Authenticated team-scoped report download endpoint serving exact
  stored evidence bytes (JSON/CSV/PDF/manifest/read-back/reconciliation).
- [x] Remediation correctness fixes with regression coverage: manual retry
  of `erp.post_customer_credit_close` now re-enqueues the close worker (the
  invoice sync worker crashed on voucher documents), and a successful retry
  from `mismatch` remediates to `reconciled` per §11.5.
- [x] LiveView tests: full happy path, exact-byte downloads, auditor
  read-only, and cross-team denial (browser + download endpoint).
- [x] GraphQL close surface over the same commands
  (`lib/billing_core_web/graphql/credit_closes/`): `creditClose`,
  `creditCloses`, `creditClosePolicies` queries; policy/generate/approve/
  post/close-period mutations with typed result unions and idempotency
  keys; base64 report access serving exact stored bytes; SDL artifact
  regenerated; HTTP tests cover the full lifecycle, idempotent replay, and
  cross-team denial (`test/graphql/credit_closes_test.exs`).
- [x] revryn `credit-closes` command group (list/get/policies/
  create-policy/generate/approve/post/accept/report with exact-byte
  download) and MCP close tools (4 read + 5 confirm-gated mutating, with
  idempotency/correlation references), both over the same GraphQL
  commands; stub-server + golden + confirm-gating tests pass; contract
  tables updated; `docs/cli/credits-close.md` and
  `docs/mcp/customer-credit-close.md` written.
- [x] Playwright close coverage: the demo e2e drives the close LiveView
  end to end (policy → generate → approve → post → reconcile → accept),
  then proves month-to-month opening continuity in-browser — the next
  calendar month opens at the accepted month's exact closing balance, and
  a zero-delta month reconciles locally without a provider voucher.
- [x] Correction parity: `closeKind`/`reversalOfCloseId`/`corrections` on
  the GraphQL type plus `requestCreditCloseReversal` /
  `generateCreditCloseReplacement` mutations (HTTP-tested end to end),
  revryn `credit-closes reverse|replace`, and confirm-gated MCP
  `reverse_credit_close` / `replace_credit_close` tools; SDL, goldens, and
  contract docs regenerated.
- [ ] Cross-interface consistency/isolation certification audit (browser +
  GraphQL denial tests exist; a recorded CLI/MCP cross-team denial pass
  against a real server remains).

Verification: `mix test test/billing_core_web/live/credit_closes_test.exs
test/workflows/customer_credit_close_workflow_test.exs` and `mix precommit`.

### BC-TASK-105 / BC-US-166 — Demo ERP first-run activation

Current slice: truthful demo workspace/provider infrastructure and the first-run
entry/resume/reset UI. The complete guided billing scenario remains a later
slice of the same task.

- [x] Durable, team-isolated demo workspace and versioned fake ERP snapshot with explicit crash/unknown-outcome recovery semantics.
- [x] Purposeful empty state with clearly separated demo and real-ERP paths.
- [x] Guided commercial → invoice → credit → aggregate close → ERP reconciliation story.
  - [x] Deterministic Northstar commercial model through ordinary
    Catalog/Contracts commands (`BillingCore.Demo.Scenario`), atomic and
    idempotent, anchored on the workspace provisioning month, with
    `Demo.mark_step/3` artifact refs (demo page phase 2).
  - [x] First-invoice phase guided through the real subscription/invoice
    surfaces; sub-state derived exclusively from the durable intent lifecycle
    + ERP document rows; booked completion recorded with draft/booked/
    reconciliation refs; interruption/resume, provider-restart, and
    provider-failure→retry workflow coverage
    (`test/workflows/demo_workspace_scenario_test.exs`).
  - [x] Customer-credit phase (4): deterministic goodwill grant through the
    ordinary account/projection/credit commands, gated on the booked invoice,
    idempotent by grant idempotency key, derived from the subledger rows,
    recorded via `Demo.mark_step/3`, with workflow + LiveView coverage.
  - [x] Aggregate close + voucher + reconciliation phase (5): guided into
    the real `/teams/:id/credit-closes` surface, derived from the durable
    close lifecycle, recorded with voucher/report-hash refs at period close,
    with workflow + LiveView coverage.
- [x] Deterministic resume/reset by linked generation without deletion of immutable financial history.
- [ ] Activation telemetry, happy/recovery Playwright paths, and qualitative usability evidence.
  - [x] Playwright deterministic happy path (`e2e/features/demo_aha.spec.ts`):
    passkey registration via CDP virtual authenticator, first-run demo
    choice, all five journey phases through the real surfaces to the closed
    month, plus mid-journey reload resume and returning-user resume.
    (Placed under `e2e/features/` — the Playwright config's testMatch — not
    the SPEC-listed root `e2e/demo_aha.spec.ts` path.)
  - [x] Playwright recoverable provider-failure path: the demo hub offers a
    one-shot "simulate a provider rejection" affordance (audited,
    fake-provider-only — no domain bypass); the induced draft failure lands
    as a failed durable operation, the journey shows needs-attention with a
    recovery explainer, and the operations-inbox retry reconciles the draft
    — covered in LiveView tests and in-browser
    (`e2e/features/demo_aha.spec.ts`, third spec).
  - [x] Activation telemetry: first-time completion of each journey step
    emits `[:billing_core, :demo, :step_completed]` with
    `seconds_since_start` (tagged by step), surfaced as a LiveDashboard
    summary metric alongside close outcome counters; emission is
    exactly-once per step, workflow-tested.
  - [ ] Qualitative usability evidence with representative prospective
    users — requires humans; only the user can arrange this.

Implementation design note: the existing `BillingCore.ERP.FakeERP` exercises
the correct adapter boundary but is process-local and test-injected. Do not
expose it as a production-looking Settings option. BC-TASK-105 needs
per-connection isolation and durable snapshot/restore before the guided UI can
truthfully promise interruption/resume or reset. That infrastructure now
exists; the next slice must orchestrate the real commercial and accounting
commands, persist artifact references with `Demo.mark_step/3`, and never mark a
journey step complete from fixture state or UI-local logic.

## Todo

### Remaining BC-TASK-104 slices (LiveView slice moved to Doing)

- [ ] GraphQL, revryn, and MCP close surfaces over the shared domain commands.
- [ ] Playwright and cross-interface consistency/isolation certification.

### Acceptance audits for substantial domain slices

These tasks have meaningful implementation and tests but need their complete
SPEC acceptance criteria checked before any promotion to `Done`:

- [ ] `BC-TASK-003`, `BC-TASK-010`, `BC-TASK-011`, `BC-TASK-012`
  — scope/audit/idempotency plus money, period, and canonical kernels.
- [ ] `BC-TASK-020`, `BC-TASK-021`, `BC-TASK-031`, `BC-TASK-040`,
  `BC-TASK-041`, `BC-TASK-042` — catalog/contracts/rating/invoice intent,
  approval, and correction domain workflows.
- [ ] `BC-TASK-050`, `BC-TASK-051`, `BC-TASK-053`, `BC-TASK-054`,
  `BC-TASK-056` — ERP port/fake/draft/sync/reconciliation core.
- [ ] `BC-TASK-082`, `BC-TASK-085`, `BC-TASK-086` — workflow corpus,
  organization/team/account domain, and passkey/TOTP/recovery core.

Next action: audit each ID against every output and acceptance bullet in the
machine-readable plan, record exact verification commands and open risks, and
split any failing criterion into an explicit Doing slice.

### Partial P0 implementation and product surfaces

- [ ] `BC-TASK-001`, `BC-TASK-002` — finish reproducible platform, migration,
  image-boot, schema-checksum, previous-release migration, and CI gates.
  - [x] Truthful CI gates slice (audit priority 1): Credo is now enforced
    (default level; `--strict` cleanup remains), and the Playwright job
    builds the production release (`mix assets.deploy` +
    `MIX_ENV=prod mix release`), migrates through
    `bin/billing_core eval "BillingCore.Release.migrate()"`, boots the
    release with the documented env contract, and runs the whole browser
    suite against it (SPEC §23.6) — verified locally: all 6 specs pass
    against the release. New operational knob `PHX_CHECK_ORIGIN`; passkey
    flows need `WEBAUTHN_ORIGIN` to match the browser origin exactly.
    `docs/runbooks/deploy-and-operate.md` records the release environment
    contract, boot/upgrade/restore procedure, and failure triage.
  - [x] Image gates: CI now builds the official image, boots the
    all-in-one profile to `/health/ready`, runs the image's own smoke-test
    and doctor profiles, and executes the backup → restore → verify cycle
    (SPEC §24.9) inside the container.
  - [x] Production bug found by the image-boot gate and fixed: the image's
    `billing` role collides with the `billing` schema via PostgreSQL's
    `"$user"` search_path, so unqualified `schema_migrations` silently
    split between schemas — readiness reported all migrations pending
    forever and a container restart would have re-run the whole chain.
    Fixed by pinning the connection `search_path` to `public` (plus
    `migration_default_prefix`); verified in-container: readiness ok,
    smoke ok, doctor all-pass, backup → restore → verify "verified" with
    73 billing tables. Second image bug fixed: `docker exec` `doctor`/
    `migrate` profiles crashed on missing `DATABASE_URL` because the
    entrypoint exported it process-locally — they now default to the
    bundled database only when the bundled cluster exists. The runbook
    documents both symptoms.
  - [x] GraphQL credit-subledger surface (BC-US-107): `creditAccounts`
    query with grants/transactions and the `grantCredit` mutation (typed
    unions, idempotent replay), HTTP-tested including cross-team denial;
    SDL regenerated.
- [ ] `BC-TASK-022`, `BC-TASK-030`, `BC-TASK-032`, `BC-TASK-033` — finish ERP
  mapping/provisioning validation, usage archival, discount consumption, and
  billing-run/late-policy boundaries.
- [ ] `BC-TASK-052`, `BC-TASK-055` — finish e-conomic preflight policy,
  webhook registration/adoption, auto-book controls, and polling certification.
- [ ] `BC-TASK-060`, `BC-TASK-061`, `BC-TASK-062`, `BC-TASK-063`,
  `BC-TASK-064`, `BC-TASK-065`, `BC-TASK-066` — finish scoped service/federated
  auth and the complete GraphQL commercial, usage, invoice, correction,
  credit, ERP, reconciliation, audit, and operations contract.
- [ ] `BC-TASK-067`, `BC-TASK-068`, `BC-TASK-069` — finish the shared admin
  shell plus complete commercial, finance, audit/export, reconciliation, and
  operations LiveView experiences.
- [ ] `BC-TASK-070`, `BC-TASK-071` — finish OTLP/correlation/diagnostics/runbooks
  and automated backup-to-restored-release verification.
- [ ] `BC-TASK-078`, `BC-TASK-079`, `BC-TASK-080`, `BC-TASK-081`,
  `BC-TASK-083` — finish GraphQL governance, docs validation/marketing,
  Storybook/design system, production-release Playwright, and signed
  single-image role certification.
- [x] `BC-TASK-087`, `BC-TASK-088` — generic SMTP delivery and
  invitation/organization/membership/security product surfaces. SPEC
  acceptance held on 2026-08-22: team switching re-authorizes server-side
  on every change (scope resolution per mount + the never-granted-team
  rejection in `multi_membership.spec.ts`), organization membership never
  implies finance permission (INV-024 matrix +
  `test/graphql/memberships_test.exs` denials), and the GraphQL
  authorization + Playwright multi-membership scenarios pass (727-test
  suite, 7-spec browser suite).
  - [x] BC-TASK-087 core: vendor-neutral SMTP transport (env-driven
    `Swoosh.Adapters.SMTP` with verified-peer TLS modes; local capture in
    dev/test), durable deduplicated delivery via the `email` Oban queue
    (unique per logical message, bounded retries, secret-free job args —
    test-enforced), security-event notifications wired into passkey
    add/revoke and recovery-code consumption, the invitation template
    ready for BC-TASK-088, `test/mail/` coverage, and
    `docs/runbooks/smtp.md`.
  - [x] BC-US-144 invitation slice: single-use, expiring, hashed-at-rest
    invitations scoped to explicit organization/team grants
    (`Orgs.invite_member/accept_invitation/revoke_invitation/
    list_invitations`, migration + append role-merge semantics without
    cross-scope escalation), best-effort invitation mail with the accept
    URL returned once, `inviteOrganizationMember`/`revoke…`/listing over
    GraphQL, and the browser accept flow (`/invitations/:token`,
    non-leaking failure copy). Six workflow + three surface tests cover
    linking an existing identity, email binding, single-use, expiry,
    revocation, additive-grants-only, and authorization.
  - [x] Membership administration UI (`/teams/:id/members`): active
    members with primary emails, team-admin role checkboxes and removal
    through new scope-authorized commands
    (`Orgs.admin_change_team_roles/admin_remove_team_member`,
    `list_team_members`), org-admin invite form with the single-use link
    shown once, pending-invitation list with revocation; tests cover admin
    actions, read-only non-admin (including a crafted-event attempt), and
    the full invite → accept loop through the page.
  - [x] Browser workspace/team creation (BC-US-140/141): the first-run
    real-ERP path now creates an organization + first team (owner/admin
    grants) through `create_organization/2`, and organization admins
    create additional teams inline on the dashboard (crafted events by
    non-admins are refused; LiveView tests cover both).
  - [x] Multi-membership Playwright scenario (BC-US-143):
    `e2e/features/multi_membership.spec.ts` drives two real users —
    invitations through the members page, one identity holding
    team_admin/auditor/billing_admin across three teams in two
    organizations, per-team affordance differences, and server-side
    rejection of a never-granted team URL. Fixed en route: a duplicate
    Oban Cron plugin entry (from the retention slice) that broke non-test
    boot — caught by the e2e harness because Oban runs `:manual` in unit
    tests; cron entries are now merged into the single plugin.
  - [x] SPEC §14.5 membership contract breadth: the full
    organizations-and-membership row is now served — admin directory
    queries `organizationMemberships`/`teamMemberships` (emails included)
    and mutations `renameTeam`, `archiveTeam` (organization-scoped via
    `targetTeamId` so an owner need not be a member of the archived team
    — a plain `teamId` input would have been captured as the scope),
    `addTeamMember` (INV-024), `changeTeamRoles`, `removeTeamMember`,
    `changeOrganizationRoles` (last-owner protected), over new
    scope-authorized `Orgs` commands. Twelve tests in
    `test/graphql/memberships_test.exs`; SDL + feature doc updated.
    `removeOrganizationMember` stays intentionally non-public per the
    SPEC table.
- [x] `BC-TASK-096`, `BC-TASK-097` — worker retry declarations, failure
  injection, and all operations-inbox remediation scenarios. Acceptance
  held on 2026-08-22: `test/workflows/failure_matrix_test.exs` enforces
  that every Oban worker declares an explicit queue + attempt bound (a
  completeness table any new worker must extend), proves queue pruning
  never removes durable operation/sync history, and proves crash-redelivery
  of a settled job repeats no external write; unknown-outcome
  reconcile-before-repeat-write and the provider-failure classes are held
  by the invoice-sync/settlement/close suites; the four BC-US-156
  Playwright scenarios pass (10-spec suite, 9.6s).
  - [x] BC-US-156 remediation taxonomy: the inbox now derives
    user-fixable / operator-only / non-retryable / automatic from the
    §22.9.1 error class, states retry safety explicitly, renders a
    copyable `revryn-support …` bundle with per-kind next-step guidance,
    hides Retry for non-retryable failures, and gates
    authorization-class remediation to team admins — in the new domain
    command `Sync.remediate_operation/2`, which also fixes a real gap the
    tests exposed: "Remediate & requeue" only flipped the operation to
    `queued` and never re-enqueued the worker job, so remediated work sat
    forever. The guided demo grew one-shot drills for all four kinds.
    Coverage: five LiveView tests (incl. finance-denied operator-only
    gating) and `e2e/features/operations_inbox.spec.ts` (self-healing
    transient, revalidate-then-requeue, non-retryable bundle) plus the
    existing user-fixable retry drill — the four BC-US-156 Playwright
    scenarios.
  - [ ] Remainder: per-worker retry declarations audit (BC-TASK-096
    "every P0 worker declares deterministic retry and terminal
    behavior") and the DB/process/provider failure matrix sweep.
- [ ] `BC-TASK-077` — capacity and data-lifecycle certification.
  - [x] Reproducible suite + measured engineering baseline (2026-08-22):
    `test/performance/capacity_test.exs` (excluded-by-default tag
    `:performance`) certifies the §21.1 objectives directly — 500-line
    preview 16.5 ms vs 5 s, single-event ingest p95 0.3 ms vs 500 ms,
    1k-batch ~3,300 events/s, 50 concurrent throttled ERP ops exactly-once
    in 221 ms, concurrent partition creation idempotent;
    `test/soak/sustained_load_test.exs` (`:soak`, SOAK_ITERATIONS) ran 300
    mixed iterations with every operation settled and non-positive BEAM
    memory growth. `docs/reviews/capacity-v1.md` records the numbers,
    sizing assumptions, and the bounded-query audit. GraphQL abuse limits
    already enforced (max_complexity 250, cardinality-weighted).
  - [ ] Blocked on environment: repeat at full §21.2 aggregate scale on
    production-like hardware, attach query plans, and calibrate provider
    throttles from real e-conomic response headers (sandbox credentials).
- [ ] `BC-TASK-101`, `BC-TASK-102` — complete all named lifecycle machines and
  diagrams, automatic downgrade/cancellation credit generation, receivable
  settlement, interfaces, and Playwright proof.
  - [x] Lifecycle diagram proof (BC-US-160): `BillingCore.Domain.Lifecycles`
    registry renders every named machine (subscription, invoice-intent/ERP
    sync, durable operation, credit grant, credit close) to the generated
    `docs/architecture/state-machines.md` (Mermaid), sync-tested so a
    transition-table change forces a reviewed doc change; linked from the
    README repo map. Backup/restore verification remains procedural
    (erp_writes_disabled mode), not a transition table — by design.
  - [x] BC-US-107 downgrade credit generation:
    `Credits.UnusedService.credit_reduction/3` (§10.1 day-based proration,
    single final rounding) opens the partial credit note through the
    ordinary correction workflow; case completion funds the subledger
    exactly once with a case-derived idempotency key and refuses (never
    skips) without a linked credit account
    (`test/workflows/unused_service_credit_test.exs` covers the 10→8-seat
    acceptance example end to end incl. FakeERP booking).
  - [x] Cancellation-disposition orchestration (BC-US-109): cancelling the
    customer's last live subscription (immediate or finalized end-of-
    period) transactionally enqueues `TerminationDispositionWorker`, which
    runs the versioned account policy — retain records, refund opens the
    durable obligation, expire_after schedules the auditable deadline —
    and surfaces a spendable balance with no policy as a
    `credits.disposition.policy_missing` audit fact for finance
    (`test/workflows/termination_disposition_test.exs`).
  - [x] Disposition-policy GraphQL surface (BC-US-109 interface bullet):
    `creditAccount.dispositionPolicy` field and the
    `setCreditDispositionPolicy` mutation (fixed policy set, typed unions),
    plus `Credits.get_credit_account/2` scoped read; HTTP-tested including
    the invalid-policy path.
  - [x] Receivable settlement (SPEC §9.4.1, BC-US-108 final bullet): the
    close posting policy now declares `settlement_mode`
    (none/erp_customer_settlement/external_reference) with
    accountant-approved clearing/contra accounts; automatic credit
    application is blocked (preview plans nothing, crafted freeze rolls
    back) until a mode is certified; each application opens exactly one
    immutable `customer_credit_settlements` row in the freeze transaction;
    erp mode posts a durable two-line clearing voucher when the invoice
    books (find-before-create, unknown-outcome recovery, read-back,
    SettlementWorker + retry routing); external mode records the reference
    exactly once. GraphQL surface (`creditSettlements`,
    `recordExternalSettlement`, policy fields), workflow + surface tests,
    accounting doc updated. E-conomic clearing-account semantics remain
    accountant/sandbox-gated like the close voucher.
  - [x] CLI/MCP credit surfaces: `revryn credits`
    (accounts/settlements/grant/set-disposition/settle-external, goldens),
    `create-policy --settlement-mode` + clearing/contra flags, MCP tools
    `list_credit_accounts`/`list_credit_settlements` (read) and
    `grant_credit`/`set_credit_disposition_policy`/
    `record_external_settlement` (confirm-gated), contracts/mcp/tools.md +
    docs/cli/credits.md; Go suite green. Also fixed en route: the
    multi-membership Playwright spec used fixed organization names that
    collided with the persistent dev database's unique slug index on
    reruns (unique suffixes now; the UI already flashed the slug-taken
    error correctly).
  - [ ] Remaining Playwright proof for the credit journey (grant →
    apply → settle in the browser) — the demo journey covers grant/close;
    application/settlement UI surfaces do not exist yet (GraphQL/CLI/MCP
    only), so browser proof follows once a finance UI slice adds them.

### Missing independent implementation or certification outputs

- [ ] `BC-TASK-072` — audit export, checksum manifest, API, retention jobs,
  and accounting/privacy policy.
  - [x] Invoice-chain audit package (BC-US-114): `BillingCore.AuditExport`
    builds canonical-JSON evidence files (chain + every immutable intent
    version with traces and state transitions; ERP documents/sync
    operations/approvals; audit-log entries) plus a SHA-256 checksum
    manifest, exposed as the `auditExport` GraphQL query; HTTP tests prove
    chain reconstruction, checksum integrity, auditor access, cross-team
    denial, and credential absence.
  - [x] Retention governance: every billing-schema table classified into
    financial_evidence / identity_access / operational in
    `BillingCore.AuditExport.Retention`, rendered to `schema/audit.yaml`
    (SDL-style sync test) with a completeness gate that fails when a new
    table lacks a class; nightly allowlist-only `RetentionWorker` (Oban
    cron 02:30 UTC) prunes webhook receipts, published outbox events,
    expired idempotency records, and dead sessions with audited per-table
    counts; six-year financial hold helper clamps configuration below the
    default; `docs/accounting/retention.md` records the policy and
    approval boundary.
  - [x] Team-configurable raw-usage retention (SPEC §20): new `raw_usage`
    retention class (usage_events only — the dedup ledger stays financial
    so pruned events can never replay), `raw_usage_retention_days` team
    setting with a 90-day floor (Settings → Data retention form),
    `Retention.enforce_raw_usage/0` in the nightly worker deleting only
    rows past both the window and the newest frozen usage cutoff through
    a transaction-scoped DB gate (ordinary DELETE stays trigger-blocked);
    audited per team. Unit + LiveView coverage; audit.yaml regenerated.
  - [x] Erasure/pseudonymization (SPEC §20):
    `BillingCore.Privacy.erase_customer/3` — team-admin gated, reason
    required, refused while live subscriptions exist; appends a redacted
    immutable customer version through the ordinary command, retains
    historical snapshots as financial evidence (DB-enforced), audits and
    emits `customer.erased.v1`. Workflow-tested;
    `docs/accounting/retention.md` extended.
- [ ] `BC-TASK-073`, `BC-TASK-074`, `BC-TASK-075`, `BC-TASK-077` — security,
  accounting, e-conomic sandbox, and capacity/data-lifecycle certification.
- [x] `BC-TASK-084` — documentation/test/schema/design-system consistency
  review: `docs/reviews/product-contract-consistency-v1.md` (2026-08-22).
  All 73 public GraphQL fields trace to docs (four gaps found and fixed:
  stale usage GraphQL section, missing ADR-031 mutations in the close doc,
  no audit-export feature doc, undocumented apiVersion); traceability
  table doc→GraphQL→integration→E2E; design-system adoption verified; the
  four artifact sync gates (SDL, audit.yaml, state-machines.md, CLI
  goldens) keep the highest-risk drift failing CI by construction.
- [ ] `BC-TASK-089`, `BC-TASK-090`, `BC-TASK-091`, `BC-TASK-092`,
  `BC-TASK-093`, `BC-TASK-094` — all three standalone showcase SaaS apps,
  standalone certification, GraphQL adapters, and integrated certification.
  - [x] BC-TASK-090 standalone (Driftbord, Django 5.2 at
    `examples/work-management-django/`, mise-pinned python): complete
    work-management product — email-login identity, organizations with
    owner/admin/member roles and last-owner protection, single-use
    email-bound invitations, projects/boards/columns/tasks, comments,
    labels, attachment metadata, saved filters, notifications,
    append-only activity history, search — plus automation rules that
    fire ONLY from the real move-task workflow, each execution metering
    an AutomationRun; the application-local billing seam
    (`billing_seam/seam.py`) prices tiered seats + graduated automation
    overage from local fixtures in integer minor units. 20 Django
    integration tests + 3-spec standalone Playwright suite (full team
    workflow incl. cross-context invitation, isolation 403, last-owner
    guard) — all green; CI job runs both plus a
    no-Billing-Core-client-before-certification grep guard (INV-030/031).
    Seeded demo via `make seed`.
  - [x] BC-TASK-089 standalone (Kystvej CRM, Rails 8.1 at
    `examples/crm-rails/`, mise-pinned ruby 3.3): complete CRM —
    email-login identity, organizations with owner/admin/member roles and
    last-owner protection, single-use email-bound invitations, companies,
    contacts with idempotent CSV import/export, pipelines with scaffolded
    stages, deals in integer øre moved through a board and settled
    won/lost, polymorphic notes, search across all three entity types,
    append-only activity history. Billing seam (`lib/billing_seam.rb`):
    base + per-active-seat, optional automation add-on, annual prepay
    (12-as-10), immediate seat increases with configurable decrease
    timing (committed floor + explicit period rollover). 15 Rails
    integration/model tests + 3-spec standalone Playwright suite (full
    sales workflow with exact 447.00/4,970.00 DKK totals, isolation 403,
    CSV round-trip without duplicates) — all green; CI job with the
    no-client guard (INV-030/031).
  - [ ] BC-TASK-091 Laravel standalone: **blocked on PHP** — mise's asdf
    php plugin hardcodes the gd extension and the machine lacks
    `libgd-dev` (no passwordless sudo). Unblock:
    `sudo apt install -y libgd-dev` then `mise install php@8.3`.
  - [x] BC-TASK-092 (partial): standalone certification recorded in
    `docs/reviews/showcase-standalone-certification.md` for the two built
    apps; Laravel row pending PHP.
  - [x] BC-TASK-093 Driftbord adapter: `billing_core/` package (stdlib
    GraphQL client with the BC-US-153 failure taxonomy, idempotent
    provisioning product→plan→version→publish→customer→contract→
    subscription, membership-driven seat quantity sync, exactly-once
    usage push per AutomationRun, preview-backed seam provider with
    fingerprint + line traceability); opt-in via DRIFTBORD_BILLING env,
    standalone untouched; 5 stub-client tests; CI guard evolved to
    "client stays behind the seam". Added the missing public
    `mapProductToErp` mutation (mirror of mapCustomerToErp, documented,
    SDL regenerated, 63 GraphQL tests green) — the integration
    legitimately required it.
  - [x] BC-TASK-094 Driftbord integrated certification
    (`e2e/showcases/run_driftbord.sh`, review in
    `docs/reviews/showcase-integrated-certification.md`): browser phase
    proves live preview traceability from real product usage; GraphQL
    phase maps ERP identities, freezes, synchronizes, and reconciles the
    intent to `erp_draft` against the demo FakeERP — no real external
    writes. The taxonomy caught a real gap en route (missing
    UpsertCustomerInput.idempotencyKey in the adapter).
  - [x] BC-TASK-093/094 Kystvej CRM: Ruby stdlib adapter
    (`lib/billing_core/` — client with the BC-US-153 taxonomy, idempotent
    provisioning, billable-seat quantity sync via the membership hook,
    preview-backed provider with traceability), seam switch env-opt-in,
    `e2e/showcases/run_crm.sh` certified both phases (live 99.00 seat +
    249.00 flat base = 348.00 DKK asserted, intent reconciled `erp_draft`
    against FakeERP); Rails CI guard evolved to the behind-the-seam
    boundary form. The flat base is platform-priced via minimum-commit
    over a zero-rate inner (SPEC §10.6) — certifying it exposed and fixed
    a real preview bug (minimum-commit components crashed into the
    metered path; regression in preview_flat_fee_test.exs). Only the
    optional add-on stays fixture config.
  - [x] BC-TASK-090…094 Personalehuset (Laravel 13 at
    `examples/employee-directory-laravel`, mise php 8.3.33 — unblocked
    without sudo via source-built libgd): complete standalone directory
    (orgs/roles/invitations, departments/locations, employees with
    managers + custom fields, onboarding checklists, search, CSV
    round-trip, change history; annual prepaid + minimum commitment +
    add-ons + prospective proration through the seam) — 17 feature tests
    + 3-spec Playwright, CI job with behind-the-seam guard. Integrated:
    PHP-streams adapter, employee-lifecycle seat sync,
    `run_personalehuset.sh` certified both phases — live 2,995.00 DKK
    preview with traceability, intent reconciled `erp_draft`, and the
    frozen line's **365-day service period** certifying BC-US-152's
    annual propagation bullet. The showcase program's engineering scope
    is complete across all three stacks.
  - [x] BC-US-157 release artifacts: `release-revryn.yml` — full
    five-target matrix (CGO off, trimmed, version-stamped), SHA256SUMS,
    SPDX SBOM, **keyless Sigstore signatures via GitHub OIDC** (no
    signing secret required), VERIFY.md, tag-triggered publishing +
    dry-run dispatch; cross-compile matrix proven locally. Awaiting only
    the first `cli/vX.Y.Z` tag.
- [x] `BC-TASK-095` — operability and Phoenix/OTP idiom review
  (`docs/reviews/operability-phoenix-v1.md`, 2026-08-22): diagnosis
  matrix for DB/queue/ERP/SMTP/backup/config families on supported
  surfaces only; the release doctor grew `smtp` and `queues` checks
  (per-state Oban counts, warn on dead work) certified with seeded
  failures and a secret-leak regression in
  `test/operability/diagnosis_test.exs`; correlation chain, runbook
  mapping, and the no-unnecessary-infrastructure report recorded.
  Follow-ups noted: alert-rule pack, notification dead-letter surfacing.
- [x] `BC-TASK-100` — CLI/MCP certification (`docs/reviews/cli-mcp-v1.md`,
  2026-08-22): `e2e/cli/run.sh` + `e2e/mcp/run.sh` drive revryn and
  the stdio MCP server against a live server with real auth — principal
  resolution, team-scoped reads (exact 12,500-minor balance round-trip),
  the settlement-mode policy mutation, stable auth/not-found failures with
  correlation ids, MCP handshake/tool discovery with readOnlyHint
  annotations, a real read call, and the confirm gate refusing
  `grant_credit` before any upstream request. CI runs both against the
  booted production release (fixture via `bin eval`). Open: signed release
  artifacts/SBOM distribution (needs a release pipeline + signing
  identity — noted in the review).
- [ ] `BC-TASK-076` — final production-readiness evidence matrix and go-live
  recommendation after all dependencies pass.
  - [x] v1 evidence matrix drafted
    (`docs/reviews/production-readiness-v1.md`): verdict NO-GO with twelve
    PASS gates (retained evidence) and nine OPEN gates split into
    user-blocked externals (sandbox credentials, accountant sign-off,
    representative users, independent security review) and implementable
    remainder with owners. Regenerate at every review until GO.

## Blocked

None currently.

## Done

No task is currently proven globally done. Every normative task is represented
under Doing or Todo and must satisfy its complete SPEC acceptance criteria
before promotion.

## Cross-cutting infrastructure (user-directed, outside SPEC task IDs)

- **Secrets via fnox + age (2026-08-22, ADR-032).** `fnox.toml` at the repo
  root is the committed, age-encrypted secret catalog (canary `FNOX_SANITY`,
  sandbox + production runtime keys declared); identities stay outside the
  repo; tooling pinned in `mise.toml`; CI `secrets-hygiene` job runs
  `fnox check`. Runbook: `docs/runbooks/secrets.md`. Gate 1 of the readiness
  matrix now reads `fnox set ECONOMIC_SANDBOX_SECRET` + `fnox exec -- mix
  run --no-start e2e/economic/certify.exs`.
- **Marketing site (user-directed, 2026-08-22).** Astro site under `site/`
  for GitHub Pages targeting engineers in SMBs/startups; documents all
  features (from `docs/features/`) and includes GraphQL API docs (from
  `schema/billing_core.graphql`). Deployed by
  `.github/workflows/site.yml` on push to `main`; live at
  https://spriz.github.io/revryn/ (the bondev.dk redirect was removed at
  the user's request).
- **Repository is public (user-directed, 2026-08-22).**
  github.com/Spriz/revryn, `main` pushed, commits now allowed (the
  earlier stage-only convention ended when the user asked to "setup git
  repo and push"). Remote CI fully green (run 32588941571). The Go
  CLI/MCP companion is named `revryn` (was billingctl); release tags use
  `cli/vX.Y.Z`. Credo is part of `mix precommit` (complexity ≤9 default,
  nesting ≤3 — refactor, never raise thresholds, per the user).

## Latest handoff snapshot

- Product codename: **Revryn**. Existing `BillingCore` module/database/API names
  remain stable unless a separately scoped compatibility migration is approved.
- The worktree is an intentionally in-progress staged set recovered after an
  interrupted agent session; inspect `git status --short` before edits and do
  not discard unrelated user changes such as `.idea/.gitignore`.
- The disposable test database was recreated and the full migration chain,
  including the close and demo-workspace migrations, migrated cleanly.
- Latest gates (after the membership-contract, receivable-settlement, and
  dialyzer slices, 2026-08-22):
  - `mix precommit` — pass; now also runs `mix dialyzer` (dialyxir added at
    the user's request; PLTs cached in `priv/plts/`, CI caches and enforces
    it, zero warnings — 87 were missing `@type t` on schema modules, the
    rest unreachable defensive clauses and three documented false-positive
    suppressions: two `Multi.new()` MapSet-opacity, one telemetry_metrics
    constructor spec).
  - 734 tests including 16 properties; seven-spec Playwright suite green
    against the prod release.
  - `gofmt`, `go vet ./...`, `go build ./...`, `go test ./...` from
    `clients/revryn/` — pass (CLI goldens include credit-closes; MCP
    tool listing covers 12 read + 11 mutating tools with confirm gating).
  - `schema/billing_core.graphql` regenerated and byte-identical to the
    compiled schema (SDL test).
  - Playwright `e2e/features/demo_aha.spec.ts` — three specs pass against
    the dev server: the full five-phase journey (passkey registration,
    reload resume, month-to-month close continuity), the returning-user
    resume, and the provider-outage → operations-inbox recovery loop.
  - `gofmt`, `go vet ./...`, `go build ./...`, and `go test ./...` from
    `clients/revryn/` — pass.
  - All five embedded `SPEC.md` YAML blocks parse; story/task/invariant ID
    duplicate checks and `git diff --check` pass.
- Local browser verification confirmed the Revryn shell/title and authenticated
  route guard. The guided surfaces are covered by LiveView tests; authenticated
  desktop/mobile visual review and the required Playwright/usability evidence
  remain open under BC-TASK-105.
- The e-conomic voucher endpoint/attachment design was checked against the
  official REST documentation; multipart field semantics still require sandbox
  certification.
- The Northstar commercial-model and first-invoice journey phases are now
  live: `BillingCore.Demo.Scenario` builds phase 2 through ordinary commands
  and derives phase 3 exclusively from durable intent/ERP rows, recording
  completions via `Demo.mark_step/3`; workflow coverage includes idempotent
  rebuild, partial-build resume, provider restart, and provider-failure →
  ordinary-retry recovery.
- Exact next product slice: guide the customer-credit application (journey
  phase 4) the same way — orchestrate/observe the ordinary credit commands
  against the booked demo invoice, record refs, and extend the workflow and
  LiveView coverage; phase 5 (aggregate close) follows the BC-TASK-104 close
  surfaces.
