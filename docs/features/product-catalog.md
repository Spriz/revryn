---
id: product-catalog
title: Product catalog
status: supported
public: true
owners: [billing-domain]
graphql:
  - Product
  - Plan
  - PlanVersion
  - PriceComponent
  - Discount
  - product
  - products
  - plan
  - planVersion
  - discount
  - createProduct
  - createPlan
  - createPlanVersion
  - publishPlanVersion
tests:
  integration:
    - test/workflows/catalog_publication_test.exs
  unit:
    - test/unit/pricing
adrs:
  - SPEC.md §8.2 Epic B, §9.4–9.6, BC-US-010…021, BC-US-060…062
---

# Product catalog

## Purpose

Own products (with accountant-approved revenue-recognition policy), plans
with immutable published versions, price components with validated pricing
definitions, discounts, and product→ERP mappings. Aggregates keep stable
team-scoped codes; content lives in immutable versions.

## User outcomes

- A billing admin defines a product once; policy changes append product
  versions and never rewrite history (BC-US-011).
- Draft plan versions are freely edited and deletable; publication freezes
  them (database-enforced) and pins existing subscriptions to their
  assigned version (BC-US-013/014).
- Discounts are published as immutable versions and attached to a contract
  or subscription for an effective interval; deactivation is prospective
  only (BC-US-060/061/062).

## Actors and permissions

Mutations: `billing_admin` or `team_admin`. ERP mapping writes:
`finance_operator`. Reads: every team role. All queries are constrained by
the scope's team.

## Domain terminology

- **Recognition policy** — `point_in_time` or `over_time` (+ mandatory
  `service_period_source` for over-time), with approver evidence fields.
- **Pricing definition** — a `schema_version: 1` map for one of the seven
  pricing models (SPEC §9.6): `fixed_recurring`, `one_time`,
  `standard_metered`, `volume_tier`, `graduated_tier`, `package`,
  `minimum_commit`. Pure data, no floats (INV-006); rates/quantities are
  decimals, monetary amounts integer minor units.
- **Content hash** — canonical SHA-256 of the published snapshot.

## Workflows

1. `create_product` — inserts the product plus immutable version 1;
   `update_product` appends the next version and moves the head; the code
   becomes immutable once any price component references the product;
   `deactivate_product` blocks future publication, historical versions stay
   valid.
2. `create_plan` → `create_draft_plan_version` (currency, `interval_unit`
   month/day, `interval_count`, `billing_timing` in_advance/in_arrears) →
   `add_price_component`/`update_price_component`/`remove_price_component`
   → `publish_plan_version` → optionally `retire_plan_version`.
3. Every `pricing_definition` is validated with
   `BillingCore.Pricing.Model.from_map/1` the moment it enters the catalog
   and stored in canonical `to_map/1` form; publication re-validates all
   components.
4. `upsert_product_erp_mapping` stores the ERP product number with
   `validation_status: "pending"`; provider validation is the ERP context's
   job (BC-US-012).
5. `create_discount` → `publish_discount_version` → `assign_discount`
   (exactly one of contract/subscription) → `deactivate_assignment`
   (prospective; never in the past, never extending the interval).

## State transitions

Plan versions: `draft` → `published` → `retired`. Drafts are mutable and
deletable; the database permits only `published → retired` on published
rows — everything else is frozen. Products: `active` → `inactive`.
Discount assignments: `active` → `deactivated`.

## Business rules / invariants

- Publication requires: at least one component; every component's product
  active with its pinned product version present; every pricing definition
  parses; over-time components carry a service-period source (SPEC §9.4,
  also database-CHECKed).
- Whole-month interval counts are limited to 1/2/3/4/6/12 (SPEC §9.5).
- A price component has no currency of its own — amounts are denominated in
  the plan version's currency.
- Component recognition defaults from the product's policy; an explicitly
  overridden recognition mode never silently inherits the product's
  service-period source.
- Publishing bumps `plans.current_version`; existing subscriptions stay
  pinned to their assigned version.
- Discount versions: `percentage` (basis_points 1..10000) XOR
  `fixed_amount` (positive `amount_minor` + currency); required priority
  and `effective_from`; `allocation_policy` defaults to `"proportional"`.

## GraphQL contract

Queries `product(s)`, `plan`, `planVersion`, `discount`; mutations
`createProduct`, `createPlan`, `createPlanVersion` (draft with components
in one command), `publishPlanVersion`.

## CLI surface

Not yet implemented (BC-US-157 planned).

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

LiveView surfaces under construction; domain commands available via GraphQL.

## Accounting / ERP effects

Product ERP mappings connect catalog products to ERP product numbers
(unique per team/connection/product; a number mapped to another product is
a changeset error). The recognition policy on the published component
drives accrual behavior downstream (see erp-synchronization).

## Async / failure / recovery behavior

All catalog writes are synchronous transactions with row locks
(`FOR UPDATE`) on the owning aggregate. Publication failures roll back with
component-tagged reasons (e.g. `{:product_inactive, code}`).

## Observability

Audit: `catalog.product.*`, `catalog.plan_version.*`,
`catalog.price_component.*`, `catalog.discount*`. Outbox:
`product.version_created.v1`, `plan.version_published.v1`,
`discount.version_published.v1`, `discount.assignment_changed.v1`.

## Tests

`test/workflows/catalog_publication_test.exs` — the full draft/publish/
immutability/v2/pinning/retire journey, publication validation failures,
recognition inheritance, interval limits, authorization.
`test/unit/pricing/` — pricing engine and discount math.

## Security / privacy

Team-scoped queries everywhere; possession of a struct never grants access
(`same_team` check). No secrets in the catalog.

## Limitations

- GraphQL `PricingDefinitionInput` currently exposes only `fixedRecurring`
  and `oneTime`; the other five models are creatable through the Elixir
  context only.
- No GraphQL surface yet for product updates/deactivation, draft edits,
  retirement, discounts, or ERP product mappings.
