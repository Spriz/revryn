# Kystvej CRM — showcase (Rails)

The Rails showcase SaaS for Billing Core (SPEC BC-US-150/153): a complete
standalone CRM — organizations with owner/admin/member roles and last-owner
protection, single-use email-bound invitations, companies, contacts with
CSV import/export, pipelines with stages, deals in integer øre through a
board, polymorphic notes, search, and an audit-friendly activity history —
with **base-plan plus per-active-seat billing** served through an
application-local billing seam.

**Standalone by construction (INV-030/031):** no Billing Core client, no
GraphQL request, no network dependency. Plan math lives in
`lib/billing_seam.rb` behind `BillingSeam.provider`; the future integration
swaps the provider and nothing else, and this standalone mode (and its
whole test suite) remains forever.

**Billing model (local fixtures):** 249.00 DKK base + 99.00 DKK per active
seat per month; optional automation add-on 149.00 DKK; annual prepay
charges 12 months as 10. Seat increases bill immediately; decreases follow
the configured timing (`immediate` or `period_end` with an explicit
period rollover). Integer minor units only.

## Run it

```sh
mise install                       # ruby via .mise.toml
mise exec ruby@3.3 -- bundle install
mise exec ruby@3.3 -- bin/rails db:prepare
mise exec ruby@3.3 -- bin/rails server   # http://localhost:3000
```

## Tests

```sh
mise exec ruby@3.3 -- bin/rails test          # 15 integration/model tests
cd e2e && npm install && npx playwright test  # standalone browser suite
```
