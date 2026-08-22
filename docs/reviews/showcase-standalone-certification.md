# Showcase standalone certification (BC-TASK-092)

Date: 2026-08-22. The hard sequencing rule (SPEC §8.11): each showcase is
functionally complete and passes its own standalone Playwright suite
before any Billing Core client exists. CI enforces the "no client before
certification" property with a grep guard per app.

## Certified standalone

| Showcase | Stack | Product scope proven | Billing model (local seam fixtures) | Evidence |
|---|---|---|---|---|
| Driftbord (`examples/work-management-django`) | Django 5.2, SQLite, server-rendered | orgs/roles/invitations (single-use, email-bound, last-owner guard), projects/boards/tasks, comments, labels, attachment metadata, saved filters, notifications, activity history, search; automation rules firing ONLY from the real move-task workflow | tiered active-member seats + 200 included automation runs + graduated overage (integer øre) | 20 Django tests; 3-spec Playwright (two-context invitation flow, exact seat/usage pricing, isolation 403, last-owner guard); CI `showcase-django` |
| Kystvej CRM (`examples/crm-rails`) | Rails 8.1, SQLite, server-rendered | orgs/roles/invitations (same guarantees), companies, contacts with idempotent CSV import/export, pipelines/stages, deals in integer øre with won/lost settlement, polymorphic notes, cross-entity search, activity history | base plan + per-active-seat, automation add-on, annual prepay (12-as-10), immediate increases + configurable decrease timing with period rollover | 15 Rails tests; 3-spec Playwright (exact 447.00 / 4,970.00 DKK totals, decrease-timing rollover, isolation 403, CSV round-trip); CI `showcase-rails` |
| Personalehuset (`examples/employee-directory-laravel`) | Laravel 13, SQLite, server-rendered | orgs/roles/invitations (same guarantees), departments, locations, employees with managers + admin-defined custom fields, scaffolded onboarding checklists with toggles, directory search, idempotent CSV import/export, change history | annual prepaid per active employee, minimum seat commitment, flat add-ons, prospective mid-term proration (integer øre) | 17 feature tests; 3-spec Playwright (exact 2,995.00/3,985.00 DKK totals with the minimum floor, isolation 403, invitation flow); CI `showcase-laravel` |

All three seams are single modules (`billing_seam/seam.py`,
`lib/billing_seam.rb`, `app/Billing/Seam.php`) — the only place
plan/entitlement questions are answered — so the integration milestone
swaps a provider, never a caller (INV-030/031). Standalone modes and
their suites remain after integration.

(The PHP toolchain was unblocked without sudo: libgd 2.3.3 built from
source into a user prefix, `PKG_CONFIG_PATH` pointed the untouched mise
plugin at it.)

