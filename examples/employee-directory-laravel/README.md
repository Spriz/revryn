# Personalehuset — employee-directory showcase (Laravel)

The Laravel showcase SaaS for Billing Core (SPEC BC-US-152/153): a complete
standalone employee directory — organizations with owner/admin/member roles
and last-owner protection, single-use email-bound invitations, departments,
locations, employees with managers and custom fields, onboarding
checklists, directory search, CSV import/export, and an audit-friendly
change history — with **annual prepaid per-active-employee billing, a
minimum seat commitment, flat add-ons, and prospective mid-term proration**
served through an application-local billing seam (`app/Billing/Seam.php`).

**Standalone by construction (INV-030/031):** integrated mode is opt-in
(`PERSONALE_BILLING=integrated`); the seam swaps to the Billing Core
provider (`app/BillingCore/`) without touching a caller, and this
standalone mode plus its whole test suite remains forever.

## Run it

```sh
mise install                            # php via .mise.toml
mise exec php@8.3 -- composer install
cp .env.example .env && mise exec php@8.3 -- php artisan key:generate
mise exec php@8.3 -- php artisan migrate
mise exec php@8.3 -- php artisan serve   # http://localhost:8000
```

## Tests

```sh
mise exec php@8.3 -- php artisan test          # 17 feature tests
cd e2e && npm install && npx playwright test   # standalone browser suite
```

## Billing model (local fixtures)

599.00 DKK per active employee per year, minimum 5 seats (configurable);
onboarding-workflows add-on 990.00/year; advanced-directory add-on
1,490.00/year; growth beyond the commitment prorates prospectively for the
remaining year. Integer øre only.
