# Product-contract consistency review v1 (BC-TASK-084)

Date: 2026-08-22. Scope: feature-doc → GraphQL → integration → E2E
traceability, plus design-system adoption. Verdict: **consistent** — the
review found four documentation gaps, all fixed in this change; the
mechanical checks below now pass clean.

## Method

1. **Public-surface trace**: every top-level field of
   `schema/billing_core.graphql` (73 queries + mutations) must appear in
   `docs/features/`, `docs/cli/`, or `docs/mcp/`. Reproduce with the
   script in this review's git change (extracts root fields, greps docs).
   Result: 73/73 documented.
2. **Artifact sync gates** (run on every `mix test`): the SDL diff test,
   `schema/audit.yaml` classification completeness against the live
   database, `docs/architecture/state-machines.md` against the compiled
   transition tables, and the CLI goldens against `revryn` output.
   Undocumented drift in any of these surfaces fails CI by construction.
3. **Doc-to-test spot-check**: each feature doc's `tests:` front matter and
   Tests section names real files; verified by ripgrep sweep.

## Findings (all fixed in this review)

| Finding | Fix |
|---|---|
| `usage-ingestion.md` claimed "no GraphQL yet" while `ingestUsageEvent`/`ingestUsageBatch`/`voidUsageEvent`/`usagePreview` shipped with HTTP tests | GraphQL section rewritten |
| `monthly-credit-close.md` omitted the ADR-031 correction mutations (`requestCreditCloseReversal`, `generateCreditCloseReplacement`) | mutations named |
| `auditExport` had no feature document | `docs/features/audit-export.md` created, indexed in the features README |
| `apiVersion` contract marker undocumented | noted in `docs/features/README.md` |

## Traceability table (supported features)

| Feature doc | GraphQL | Integration tests | E2E |
|---|---|---|---|
| organizations-and-teams | org/team/membership row (§14.5, complete) | organization_lifecycle, scope_resolution, memberships (GraphQL) | multi_membership.spec |
| passkey-authentication | sessions via Bearer; WebAuthn is browser-native | authentication workflow | every spec (fixtures/auth) |
| customers-and-contracts | upsertCustomer, mapCustomerToErp, contracts | customer_management, correction | demo journey |
| product-catalog | products/plans/discount mutations | catalog_publication | demo (commercial phase) |
| subscriptions | create/change/cancel | subscription_lifecycle, annual_prepaid | demo journey |
| usage-ingestion | ingest/void/usagePreview | usage_ingestion, metered_billing | — (API-only surface) |
| invoice-preview-and-freeze | invoicePreview, freezeInvoiceIntent, supersede | invoice_sync, billing_run | demo journey |
| erp-synchronization | synchronize/approve/book/retryOperation | invoice_sync, external_booking, failure_matrix | demo + operations_inbox specs |
| billing-runs | createBillingRun, billingRun | billing_run | demo journey |
| corrections-and-credit-notes | (via correction workflow surfaces) | correction, unused_service_credit | — |
| customer-credit | grantCredit, creditAccounts, disposition, settlements | customer_credit, credit_application, receivable_settlement, termination_disposition | demo (credit phase) |
| monthly-credit-close | full close row incl. ADR-031 corrections | customer_credit_close_workflow | demo (close phase) + close continuity |
| operations-and-failure-inbox | operation, retryOperation | failure_matrix, invoice_sync | operations_inbox.spec (4 scenarios) |
| audit-export | auditExport | audit_export (GraphQL), retention (unit) | — (auditor API surface) |
| demo-workspace | — (LiveView-only by design) | demo_workspace, demo_workspace_scenario | demo_aha.spec (3) |
| annual-prepaid-subscriptions | (subscriptions surface) | annual_prepaid_subscription | demo journey (annual line) |

## Design-system adoption

All LiveViews render through `<Layouts.app>`, use `core_components`
(`<.input>`, `<.button>`, `<.header>`, `<.icon>`) with Tailwind utility
classes, list-syntax class attributes, and stable DOM ids consumed by the
LiveView tests and Playwright suites. No `@apply`, no inline scripts (the
one page script is a colocated hook), no vendored assets outside the
app.js/app.css bundles.

## Follow-ups

- The traceability script should graduate into a test if doc drift recurs
  (today the artifact sync gates cover the highest-risk drift).
- corrections/audit-export gain browser coverage when a finance UI slice
  adds their surfaces (tracked in TODO.md).
