# SPEC implementation gap audit

> **Superseded (2026-08-22, end of day).** This morning audit predates
> the day's delivery. The authoritative current state is
> [`production-readiness-v1.md`](production-readiness-v1.md) (rev 5) and
> the evidence-annotated checklists in [`TODO.md`](../../TODO.md).
> Retained unchanged below for the historical record of where the day
> started.

Audit date: 2026-08-22

Normative source: [`SPEC.md`](../../SPEC.md)

Operational ledger: [`TODO.md`](../../TODO.md)

## Executive verdict

Revryn contains a substantial billing-domain implementation, but it does not
yet satisfy the production-build specification. The machine-readable work plan
defines 69 real `BC-TASK` entries and the functional scope defines 113
`BC-US` stories. Before this audit, `TODO.md` mentioned only five real task IDs
and one story ID.

No task should currently be treated as globally `Done`. Several domain slices
look close to their task-level acceptance criteria, but the specification makes
tests, observability, documentation, migrations, interface parity, and release
certification part of completion. Those gates are not present end to end.

The largest release blockers are:

1. No P0 Playwright feature suite exists. `e2e/features/` has no scenarios;
   only two public-page/health smoke specs exist, and CI starts the app through
   `mix phx.server` rather than the built production release.
2. The public/product interfaces are incomplete. GraphQL, LiveView,
   `revryn`, and MCP do not expose the same supported domain commands.
3. Production operations are not certified. Security, accounting, capacity,
   restore, sandbox, operability, and production-readiness evidence is absent.
4. Customer-credit close correction/product-surface work and the guided demo
   story are explicitly unfinished.
5. Invitations and transactional SMTP email are not implemented as product
   workflows.
6. All three showcase SaaS applications and their standalone/integrated
   certification are absent.

## Method and status meanings

This is a repository audit, not an external environment certification. It
compares the specification to committed/staged source, migrations, feature
documentation, tests, CI, and release tooling. A provider sandbox, signed OCI
artifact, platform release matrix, backup restore environment, or accountant
approval cannot be inferred from source code.

- **Substantial**: the task's main domain output exists and has meaningful
  automated coverage, but its full acceptance report is still missing.
- **Partial**: relevant implementation exists, but one or more named outputs or
  acceptance criteria are visibly absent.
- **Missing/certification absent**: the task's primary output or required
  independent evidence is not present.

## Feature gaps by SPEC epic

| Epic | Status | Missing or incomplete features |
| --- | --- | --- |
| A — Team and ERP configuration | Partial | Team/settings and connection preflight exist. Missing: provider webhook registration/adoption, customer provisioning, auto-book enablement/suspension policy, complete secret-store lifecycle, and e-conomic sandbox certification. |
| B — Products, plans, recognition | Partial | All seven pricing kernels exist in Elixir. GraphQL exposes only fixed-recurring and one-time pricing creation; full plan/component editing, discounts, mappings, and retirement are not exposed consistently. Period-limited discount reservation/commit/release persistence is absent. |
| C — Customers, contracts, subscriptions | Partial | Core aggregates and several LiveViews/GraphQL mutations exist. Missing or incomplete: contract amendments, approved price-override workflow, scheduled-change cancellation, ERP customer provisioning/validation, and interface parity for plan change, pause/resume, and one-time-charge cancellation. |
| D — Usage ingestion and rating | Partial | Single/batch ingestion, void/replacement, aggregation, partitions, and rating exist. Missing: quarantine/operator tooling, safe partition archival/retention guards, automatic open-period recalculation and booked-period correction orchestration, and UI/CLI/MCP surfaces. |
| E — Discounts, proration, invoice construction | Partial | Pricing, proration, preview, freeze, hashing, and billing-run consolidation are implemented. Missing: period-count discount consumption lifecycle, complete public discount commands, and full browser workflow proof. |
| F — e-conomic synchronization | Partial | Draft create/update, booking, polling, read-back reconciliation, unknown-outcome recovery, and finance vouchers exist. Missing: webhook registration management, customer provisioning, auto-book policy, incident workflow/automatic suspension, full preflight policy coverage, and sandbox certification. |
| G — Credits, rebilling, exceptions | Partial, major gaps | Full/partial credit and rebill domain commands exist, but correction GraphQL/CLI/MCP surfaces are absent. Customer-credit ledger/disposition exists, but downgrade-to-credit orchestration, receivable-settlement integration, termination triggering, and all required product interfaces/Playwright paths are incomplete. Monthly close reversal/replacement, prior-period correction, product surfaces, sandbox attachment proof, and the guided demo story remain open. |
| H — Operations, audit, reporting | Partial, major gaps | Calculation traces, billing-run views, durable operations, and per-document reconciliation exist. Missing: cross-field invoice/sync search, daily reconciliation incident workflow, audit package export/checksum manifest, retention jobs/policy, complete auditor surfaces, and operational certification. |
| I — Platform, API, docs, operability | Partial, major gaps | LiveView, GraphQL, container, backup scripts, and feature docs have foundations. Missing: production-release Playwright workflows, GraphQL persisted/allowlist mode and complete abuse limits, breaking-change CI, N+1 plan tests, signed/multi-platform image evidence, automated restore smoke certification, docs schema/validator/contribution workflow, Storybook stories/accessibility tests, and Astro marketing build. |
| J — Organizations, identity, operations, CLI/MCP | Partial, major gaps | Organization/team/account domain, passkeys, TOTP, recovery codes, operations, basic CLI, and stdio MCP tools exist. Missing: invitation tokens/workflow, organization/team administration surfaces, service/OIDC login completion, generic SMTP delivery flows, complete diagnostics/OTLP/runbooks, failure-injection matrix, CLI profiles/release packaging/full command breadth, MCP Streamable HTTP/resources/capability grants/security conformance, and full lifecycle-machine coverage. |
| K — Showcase SaaS applications | Missing | Rails CRM, Django work management, Laravel employee directory, standalone certification, GraphQL adapters, and integrated Playwright certification are all absent. |

## Cross-cutting evidence gaps

### Playwright and workflow proof

- `e2e/features/` contains no `*.spec.ts` files.
- `e2e/smoke/` contains only health and public-home smoke tests.
- CI runs `mix phx.server`; it does not exercise the built
  production release, a signed image, authenticated feature workflows, the
  stateful fake ERP, restore validation, or the required failure cases.
- There is no browser proof for passkeys, conflicting roles across two
  organizations/three teams, customer credit, corrections, async remediation,
  credit close, or the demo journey.

This leaves `INV-018`, `INV-032`, and especially `BC-US-123` unproved
across every user-visible feature.

### GraphQL contract and interface parity

The schema currently has 22 query fields and 24 mutation fields, which is a
useful vertical slice, not the task-wide public contract. Notable omissions
include:

- credit balances, grants, transactions, policies, refunds, expiries, and
  close queries/mutations/report access;
- correction-case and credit/rebill mutations;
- invoice/synchronization history search, reconciliation, incidents, audit
  log/export, and billing-run close;
- team membership, invitations, team archival/settings, accounts, and
  security administration;
- full catalog/discount/mapping and subscription lifecycle commands;
- operations inbox listing and typed remediation commands.

Transport controls cover document bytes and weighted complexity, but the
specified token, depth, execution-time, resolver fan-out, and persisted
operation/allowlist controls are not implemented. CI checks SDL freshness but
does not run a schema breaking-change comparison. There is a batch resolver,
but no representative query-count/N+1 growth test.

### CLI and MCP

`revryn` currently covers status, customer reads, subscription
read/create, invoice preview/freeze/sync/approve/book, operation get/retry,
billing-run create/get, doctor, and MCP stdio startup. This is narrower than
`BC-US-157`: there are no login/profile commands, organization/team
administration, catalog/plans, usage import, correction/credit/close,
reconciliation, backup/restore orchestration, or schema/capability command
set. There is no cross-platform packaging/signing/SBOM pipeline or CLI E2E
suite against the production release.

MCP has bounded semantic tools and confirmation gates, but only stdio is
wired. Streamable HTTP, MCP resources, independent read/mutate grants,
credit-close capabilities, and protocol/security tests for cross-team
isolation, injection resistance, oversized inputs, cancellation, timeout, and
retries are missing.

The feature docs are also stale: many still say CLI/MCP are “not yet
implemented” even though partial implementations now exist.

### Operations, release, and recovery

- Structured logging and Prometheus metrics exist, but OpenTelemetry/OTLP is
  not configured and the required product/backup/email/ERP metric catalogue
  and correlation proof are incomplete.
- Health endpoints and a basic release `doctor` exist, but there is no
  authenticated product diagnostics page with build identity, migrations,
  SMTP, ERP, backup, restore, and linked correlation evidence.
- Backup/restore shell tooling and an all-in-one image definition exist, but
  CI does not build/sign the image, create a backup, restore it, boot the
  restored release in no-write mode, or run the required authenticated
  Playwright smoke flow. Backup metadata also lacks several required identity,
  version, configuration, and secret-policy fields.
- No runbook files, performance/soak tests, sandbox suite, or operability,
  security, accounting, capacity, or production-readiness evidence exists.
- CI ignores Credo failures (`|| true`) and has no Dialyzer, docs, Storybook,
  restore, observability, doctor, state-machine, domain-event, credit-close,
  CLI/MCP contract, secret, dependency, or OCI image gate from SPEC §28.5.

### Documentation and design system

There are 15 canonical feature documents, but no `_schema.yml`, template,
coverage validator, `CONTRIBUTING.md`, supported-feature cross-reference gate,
or Astro content pipeline. Several documents marked `supported` contain
limitations that contradict required acceptance criteria or stale interface
claims.

Phoenix components exist, but there is no Storybook configuration/story
corpus, component-state matrix, accessibility smoke suite, or adoption review.
The current CSS and components still depend heavily on daisyUI rather than the
specified repository-owned design system.

## Task inventory

### Substantial implementation; acceptance audit still required

| Tasks | Existing evidence | Remaining audit concern |
| --- | --- | --- |
| `BC-TASK-003`, `010`, `011`, `012` | Scope/audit/idempotency modules; Money, Period, Canonical kernels and unit/property tests | Prove every mutable command uses the foundations transactionally and run the complete invariant/golden/property matrix. |
| `BC-TASK-020`, `021`, `031`, `040`, `041`, `042` | Catalog, contracts/subscriptions/charges, pricing engine, invoice intent, approvals, corrections, and workflow tests | Resolve the interface and lifecycle gaps above; produce task completion reports and full browser evidence. |
| `BC-TASK-050`, `051`, `053`, `054`, `056` | Adapter port, stateful fake ERP, e-conomic draft/book/read normalization, durable sync operations, comparator/reconciliation tests | Complete provider capabilities, incident handling, certification, and cross-interface evidence. |
| `BC-TASK-082`, `085`, `086` | Workflow test corpus; organization/team/account domain; passkey/TOTP/recovery domain and LiveViews | Expand coverage to all P0 workflows and add the missing invitation, multi-scope browser, and virtual-authenticator evidence. |

These IDs are candidates for focused acceptance audits, not declarations of
completion.

### Partial tasks with concrete missing outputs

| Tasks | Missing boundary |
| --- | --- |
| `BC-TASK-001`, `002` | Reproducible toolchain/CI gate set, image boot proof, schema checksum and previous-release migration checks. |
| `BC-TASK-022`, `030`, `032`, `033` | ERP provisioning/validation, usage archival/retention, discount consumption lifecycle, and complete late/run policy evidence. |
| `BC-TASK-052`, `055` | Full e-conomic connection/preflight policy, webhook registration/adoption, auto-book safety policy, and provider certification. |
| `BC-TASK-060`, `061`, `062`, `063`, `064`, `065`, `066` | Service/federated auth completion and the missing GraphQL commercial, usage, correction, credit, audit, reconciliation, and operations commands. |
| `BC-TASK-067`, `068`, `069` | Complete admin navigation/forms, commercial setup, usage/correction flows, finance search/audit/export/reconciliation, and browser accessibility/reconnect evidence. |
| `BC-TASK-070`, `071` | OTLP/correlation/diagnostics/runbooks and automatic backup-to-restored-release certification. |
| `BC-TASK-078`, `079`, `080`, `081`, `083` | GraphQL governance/limits; docs schema/validator/contribution/marketing; Storybook/design-system proof; P0 feature E2E; image build/sign/role certification. |
| `BC-TASK-087`, `088` | Generic SMTP workflows and retries; invitations plus complete organization/membership/security GraphQL and LiveView surfaces. |
| `BC-TASK-096`, `097` | Complete worker retry declarations/failure-injection matrix and all required operations-inbox remediation scenarios. |
| `BC-TASK-098`, `099` | Full CLI breadth/release contract and MCP HTTP/resources/grants/conformance/security contract. |
| `BC-TASK-101`, `102` | Explicit machines/diagrams for every named lifecycle; automatic downgrade/cancellation credit orchestration, settlement integration, interfaces, and Playwright. |
| `BC-TASK-103`, `105` | Close correction/sandbox work; complete guided commercial-to-accounting demo, activation telemetry, Playwright, and usability evidence. |

### Missing tasks or independent certification artifacts

| Tasks | Required output not present |
| --- | --- |
| `BC-TASK-072` | Audit export and retention implementation, API, manifest, and policy. |
| `BC-TASK-073`, `074`, `075`, `077` | Security, accounting, e-conomic sandbox, and capacity/data-lifecycle certification. |
| `BC-TASK-084` | Docs/tests/schema/design consistency review. |
| `BC-TASK-089`, `090`, `091`, `092`, `093`, `094` | All three showcase applications, standalone certification, GraphQL adapters, and integrated certification. |
| `BC-TASK-095` | Operability/Phoenix idiom certification. |
| `BC-TASK-100` | CLI/MCP release and agent-safety certification. |
| `BC-TASK-104` | Customer-credit-close LiveView, GraphQL, CLI, MCP, report-download, and Playwright surfaces. |
| `BC-TASK-076` | Final production-readiness evidence matrix and go-live recommendation. |

## Recommended execution order

1. Make the gates truthful: production-release Playwright harness, CI failure
   enforcement, image build, docs/schema checks, and restore verification.
2. Finish shared public contracts before adding more UI: GraphQL breadth and
   protection, then align LiveView, CLI, and MCP on the same commands.
3. Close P0 accounting gaps: customer-credit orchestration/settlement,
   correction surfaces, credit-close corrections/surfaces, ERP policy/webhook
   behavior, and sandbox certification.
4. Finish identity/operations: invitations, SMTP, diagnostics, runbooks,
   failure remediation, audit export, reconciliation incidents, and retention.
5. Complete the guided demo against real domain commands and add the full P0
   browser suite.
6. Run security, accounting, capacity, operability, product-contract, CLI/MCP,
   and production-readiness reviews.
7. Treat the P1 marketing/showcase program as a separate milestone after the
   P0 production gates are green.

## Audit limitations

This report does not promote any task to `Done`. It also does not claim an
external provider behavior, signed artifact, backup recoverability, performance
target, accountant approval, or usability result without retained evidence.
Dirty/staged work was preserved and evaluated as part of the current repository
state.

## Verification at audit handoff

- Normative task-ID coverage check: all 69 work-plan task IDs occur in
  `TODO.md`; no placeholder/example ID was counted.
- `git diff --check`: pass.
- `gofmt`, `go vet ./...`, `go build ./...`, `go test ./...` in
  `clients/revryn/`: pass.
- `mix precommit`: 654/655 tests pass, including 16/16 properties. The one
  failure belongs to the concurrently active `BC-TASK-105` demo slice:
  `DemoLiveTest` expects the commercial phase to remain “Upcoming,” while the
  in-progress page now exposes its real commercial-model action. This audit
  does not overwrite that active implementation or guess its final assertion.
- A subsequent format check found the concurrently added
  `test/workflows/demo_workspace_scenario_test.exs` unformatted. It is part of
  the same unsettled demo slice and was not edited by this audit.
