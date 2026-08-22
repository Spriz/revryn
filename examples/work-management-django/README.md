# Driftbord — work-management showcase (Django)

The Django showcase SaaS for Billing Core (SPEC BC-US-151/153): a complete
standalone work-management product — organizations, projects, boards,
tasks, comments, labels, attachments metadata, invitations, roles, search,
saved filters, notifications, audit-friendly activity history — with
**tiered active-member pricing plus metered automation usage** served
through an application-local billing seam.

**Standalone by construction (INV-030/031):** no Billing Core client, no
GraphQL request, no network dependency exists in this application. Plan
and entitlement answers come from local fixtures behind
`billing_seam/seam.py::get_provider()`; the future integration milestone
swaps that provider and nothing else, and this standalone mode (and its
whole test suite) remains forever.

**Metered usage is real:** automation rules fire when tasks are moved
into a column by actual users; every execution records an
`AutomationRun`, which is exactly what the seam counts — there is no
billing-demo screen generating synthetic events.

## Run it

```sh
mise install          # pins python via .mise.toml
make setup            # venv + Django
make migrate
make seed             # demo org — demo@driftbord.example / sikkerhed123
make serve            # http://localhost:8300
```

## Tests

```sh
make test             # 20 Django integration tests
cd e2e && npm install && npx playwright test   # standalone browser suite
```

## Billing model (local fixtures)

- Seats: Studio ≤5 @ 49.00, Agency ≤20 @ 39.00, Scale @ 29.00 DKK per
  active member/month.
- Automation: 200 runs/month included, then graduated overage
  (300 @ 0.50, 500 @ 0.35, rest @ 0.20 DKK). Integer minor units only.
