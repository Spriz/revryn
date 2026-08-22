# Showcase integrated certification (BC-TASK-094)

Date: 2026-08-22. BC-US-153: `integrated` mode boots Billing Core plus the
showcase, configures an integration client, executes cross-system browser
scenarios, and reaches the e-conomic fake adapter without real external
writes. Standalone modes and their suites remain untouched (INV-031).

## Reproduce

```sh
REVRYN_DEMO_ERP_ENABLED=true mix phx.server &
BASE_URL=http://localhost:4000 e2e/showcases/run_driftbord.sh
```

The fixture (`e2e/showcases/fixture.exs`) provisions a guided demo
workspace — a real team with a validated FakeERP connection — and mints a
bearer session that becomes the showcase's integration credential.

## Driftbord × Billing Core — certified

**Phase 1 (browser, `e2e/showcases/driftbord/integrated.spec.ts`):**
Driftbord boots in integrated mode (`DRIFTBORD_BILLING=integrated`, URL /
token / team via env). A real user registers, creates an organization
(→ `upsertCustomer` + `createContract` + `createSubscription` through the
public GraphQL contract, quantity = active members), builds a project with
an automation rule, and moves a task through the real workflow
(→ `ingestUsageEvent` keyed by the AutomationRun id). The billing page
renders the **live Billing Core invoice preview** — fingerprint plus
line-level traceability (`#preview-traceability`), satisfying the
BC-US-151 "visibly demonstrates invoice preview traceability" bullet.

**Phase 2 (GraphQL, same run):** the runner maps the showcase-created
customer and product to the demo FakeERP connection
(`mapCustomerToErp` / `mapProductToErp`), freezes the subscription's
intent, requests synchronization, and polls until the intent state is
**`erp_draft`** — draft created and read-back reconciled against the fake
adapter, no real external writes.

**Failure taxonomy (BC-US-153):** the adapter distinguishes
`ConfigurationError`, `AuthenticationError`, `ContractError`, and
`DomainRejection` (typed-problem unions), unit-tested in
`billing_core/tests.py`. During certification the taxonomy caught a real
contract gap: the adapter omitted `UpsertCustomerInput.idempotencyKey`
and the failure surfaced as a ContractError with the exact argument.

## Kystvej CRM × Billing Core — certified

Same pattern, Ruby stdlib client (`lib/billing_core/`), reproduced with
`e2e/showcases/run_crm.sh`. Phase 1: the CRM boots integrated
(`KYSTVEJ_BILLING=integrated`), a real user creates an organization
(→ full provisioning chain, quantity = billable seats — the CRM's
decrease-timing rule stays authoritative and flows through as quantity),
and the billing page renders the live preview: 1 seat at exactly
99.00 DKK with fingerprint + line traceability. Phase 2: map both ERP
identities, freeze, synchronize — the intent reconciled as **`erp_draft`**
against the fake adapter.

Recertified fully platform-priced: the flat base plan is a
minimum-commit component over a zero-rate fixed inner (SPEC §10.6) — the
contract's native flat-fee shape — so the browser asserts the exact live
totals 99.00 (seat) + 249.00 (base) = 348.00 DKK. Only the optional
automation add-on remains commercial fixture config. This certification
found and fixed a real platform bug: the invoice preview routed
minimum-commit components into the metered path and crashed; regression
pinned in `test/unit/billing/preview_flat_fee_test.exs`.

## Personalehuset × Billing Core — certified

PHP-streams client (`app/BillingCore/`), reproduced with
`e2e/showcases/run_personalehuset.sh`. Phase 1: a real hire drives the
billable annual-prepaid quantity (minimum-commitment floor of 5) and the
billing page renders the live preview — 5 × 599.00 = 2,995.00 DKK with
fingerprint + line traceability. Phase 2: map, freeze, synchronize — the
intent reconciled as **`erp_draft`**, and the frozen line's service
period spans **365 days**, certifying BC-US-152's
"service-period propagation for annual prepaid lines" bullet via the
public contract. (Integration env reaches artisan-serve workers through
the `.env` file — process env does not reliably propagate; the runner
appends and restores it.)

All three showcases are now certified standalone AND integrated; the
showcase program's engineering scope (BC-TASK-089…094) is complete.
