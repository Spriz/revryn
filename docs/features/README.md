# Feature documentation

Canonical product documentation per SPEC §24.10 (INV-021: these markdown
feature documents are the product source of truth; behavior-changing pull
requests update the relevant document in the same change). Front matter is
machine-readable; only `public: true` documents are imported by the
marketing/documentation site.

| Feature | Status | Doc | Key tests |
| --- | --- | --- | --- |
| Organizations and teams | supported | [organizations-and-teams.md](organizations-and-teams.md) | `test/workflows/organization_lifecycle_test.exs`, `test/workflows/scope_resolution_test.exs` |
| Passkey authentication | supported | [passkey-authentication.md](passkey-authentication.md) | `test/workflows/authentication_test.exs` |
| Product catalog | supported | [product-catalog.md](product-catalog.md) | `test/workflows/catalog_publication_test.exs` |
| Customers and contracts | supported | [customers-and-contracts.md](customers-and-contracts.md) | `test/workflows/customer_management_test.exs` |
| Subscriptions | supported | [subscriptions.md](subscriptions.md) | `test/workflows/subscription_lifecycle_test.exs` |
| Usage ingestion | supported | [usage-ingestion.md](usage-ingestion.md) | `test/workflows/usage_ingestion_test.exs`, `test/workflows/metered_billing_test.exs` |
| Invoice preview and freeze | supported | [invoice-preview-and-freeze.md](invoice-preview-and-freeze.md) | `test/workflows/annual_prepaid_subscription_test.exs`, `test/workflows/credit_application_test.exs` |
| Billing runs | supported | [billing-runs.md](billing-runs.md) | `test/workflows/billing_run_test.exs` |
| ERP synchronization | supported | [erp-synchronization.md](erp-synchronization.md) | `test/workflows/invoice_sync_test.exs`, `test/workflows/external_booking_test.exs` |
| Corrections and credit notes | supported | [corrections-and-credit-notes.md](corrections-and-credit-notes.md) | `test/workflows/correction_test.exs` |
| Customer credit | supported | [customer-credit.md](customer-credit.md) | `test/workflows/customer_credit_test.exs`, `test/workflows/credit_application_test.exs` |
| Operations and failure inbox | supported | [operations-and-failure-inbox.md](operations-and-failure-inbox.md) | `test/workflows/invoice_sync_test.exs`, `test/workflows/customer_credit_test.exs` |
| Annual prepaid subscriptions | supported | [annual-prepaid-subscriptions.md](annual-prepaid-subscriptions.md) | `test/workflows/annual_prepaid_subscription_test.exs`, `test/workflows/invoice_sync_test.exs` |

Conventions: each document carries the §24.10 front matter
(`id`, `title`, `status`, `public`, `owners`, `graphql`, `tests`, `adrs`)
and the required sections. State-machine sections embed Mermaid diagrams
generated from the implemented transition tables
(`BillingCore.Contracts.subscription_machine/0`,
`BillingCore.Billing.IntentMachine`, `BillingCore.Operations.machine/0`,
`BillingCore.Credits.grant_machine/0`). CLI (`billingctl`, BC-US-157) and
MCP (BC-US-158) surfaces are planned but not yet implemented; those
sections say so per document rather than restating spec aspirations.
