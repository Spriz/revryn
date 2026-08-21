# Billing Core E2E (Playwright)

End-to-end suites for Billing Core, governed by SPEC section 23.6. Playwright is a
required dependency of the repository even though the product UI is
server-rendered.

## Layout

```
e2e/
├── features/    # complete product workflows (P0 scenarios)
├── smoke/       # deploy/restore smoke tests (health, boot, render)
├── fixtures/    # shared test data, helpers, auth setup
├── playwright.config.ts
└── package.json
```

## Running

```bash
cd e2e
npm install
npx playwright install chromium   # first time only
npx playwright test               # everything
npx playwright test smoke         # smoke suite only
npx playwright test features      # feature workflows only
npx playwright show-report        # open the HTML report
```

The config's `webServer` block boots the Phoenix dev server (`mix phx.server`
at the repo root, via mise) on port 4000 and reuses an already-running server
if one is listening. The first boot compiles the app, so the server timeout is
generous (180s). Postgres must be up (dev default: 127.0.0.1:55432) with
migrations applied (`mix ecto.migrate`).

Note: SPEC 23.6 requires browser tests to run against a compiled production
Phoenix release with built assets in CI. The dev-server `webServer` command
here is the local-iteration convenience; the CI pipeline should point the same
suites at the release build.

## Policy (SPEC 23.6) — non-negotiable

- **`retries: 0`** for required suites. A flaky test is a bug, not a retry
  candidate. A separate diagnostic retry job may exist in CI but cannot affect
  merge status. Do not add `retries` overrides or `test.describe.configure`
  retry bumps to required specs.
- **Evidence retention**: failed runs retain Playwright traces, screenshots,
  video, relevant HTML, browser console, Phoenix logs, worker logs, and
  fake-provider logs. The config keeps trace/screenshot/video on failure and
  pipes the webServer's stdout/stderr; CI must archive `test-results/` and
  `playwright-report/`.
- **Selectors**: prioritize accessible roles, labels, names, and stable
  user-facing semantics — `getByRole`, `getByLabel`, `getByText` with exact
  user-visible strings. Avoid CSS/XPath tied to markup structure; do not
  invent `data-testid`s where an accessible name exists.
- **No transport stubbing**: tests run against real PostgreSQL and the
  stateful fake ERP; LiveView HTTP/WebSocket traffic is never stubbed.
- **Authentication**: a test OIDC provider or deterministic test identity
  boundary is acceptable, but authorization stays real.
- **Duplicate submission/reconnect**: every LiveView that submits financial or
  synchronization commands must have a test covering duplicate submission and
  reconnect behavior.

## Conventions for future feature specs

- One workflow per file under `features/`, named after the business scenario
  (e.g. `features/annual-prepaid-invoice-preview.spec.ts`), readable as
  product documentation.
- P0 scenarios to cover (SPEC 23.6): team setup, product/plan publication,
  customer/subscription creation, annual prepaid invoice preview, draft
  synchronization, reconciliation, approval/booking simulation, correction,
  audit inspection, and restore smoke validation.
- Shared setup (seeded orgs, login helpers, fake-ERP state) belongs in
  `fixtures/`, exposed as Playwright fixtures — not copy-pasted into specs.
- Test data policy (SPEC 23.12): synthetic customers and addresses only;
  never real ERP tokens or invoice data.
- Assert durable business outcomes visible to the user, not implementation
  details.
