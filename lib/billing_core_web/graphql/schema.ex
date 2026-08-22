defmodule BillingCoreWeb.GraphQL.Schema do
  @moduledoc """
  Public GraphQL schema (SPEC §14, INV-017).

  The schema is the general-purpose machine API; LiveView calls domain
  contexts directly and never round-trips through this endpoint. Capabilities
  are added per SPEC §14.5 as their domain contexts land; evolution is
  additive (INV-023).

  Every organization/team-owned field resolves an explicit scope through
  `Middleware.RequireScope` (SPEC §14.2); business mutations return typed
  result unions (SPEC §14.4); connections are bounded keyset cursors with
  cardinality-weighted complexity (SPEC §14.6/§14.7); resolver crashes are
  sanitized by `Middleware.SafeResolution`.
  """

  use Absinthe.Schema

  alias BillingCoreWeb.GraphQL.{CreditCloses, Middleware, Pagination, Resolvers}

  import_types(BillingCoreWeb.GraphQL.Scalars)
  import_types(BillingCoreWeb.GraphQL.Types)
  import_types(BillingCoreWeb.GraphQL.Types.Contracts)
  import_types(BillingCoreWeb.GraphQL.Types.Catalog)
  import_types(BillingCoreWeb.GraphQL.Types.Billing)
  import_types(BillingCoreWeb.GraphQL.Types.Erp)
  import_types(BillingCoreWeb.GraphQL.Types.Usage)
  import_types(BillingCoreWeb.GraphQL.Types.Credits)
  import_types(BillingCoreWeb.GraphQL.CreditCloses.Types)
  import_types(BillingCoreWeb.GraphQL.Audit.Types)
  import_types(BillingCoreWeb.GraphQL.Organizations.Types)

  def middleware(middleware, _field, _object) do
    Enum.map(middleware, fn
      {{Absinthe.Resolution, :call}, resolver} -> {Middleware.SafeResolution, resolver}
      other -> other
    end)
  end

  # Batch resolution (customer legalName etc.) needs the Batch plugin.
  def plugins do
    [Absinthe.Middleware.Batch] ++ Absinthe.Plugin.defaults()
  end

  query do
    @desc "Schema/contract version marker for compatibility checks."
    field :api_version, non_null(:string) do
      resolve(fn _, _, _ -> {:ok, "1"} end)
    end

    @desc "The authenticated principal and its memberships."
    field :viewer, :viewer do
      resolve(&Resolvers.Orgs.viewer/3)
    end

    @desc "Organizations the caller actively belongs to."
    field :organizations, non_null(list_of(non_null(:organization))) do
      resolve(&Resolvers.Orgs.organizations/3)
    end

    @desc "A single organization the caller belongs to."
    field :organization, :organization do
      arg(:organization_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Orgs.organization/3)
    end

    @desc "A team the caller is a member of."
    field :team, :team do
      arg(:team_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Orgs.team/3)
    end

    @desc "Active teams of an organization the caller belongs to."
    field :teams, non_null(list_of(non_null(:team))) do
      arg(:organization_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Orgs.teams/3)
    end

    @desc "A team customer by ID."
    field :customer, :customer do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Contracts.customer/3)
    end

    @desc "Team customers as a bounded cursor connection (SPEC §14.6)."
    field :customers, :customer_connection do
      arg(:team_id, non_null(:id))
      arg(:first, :integer)
      arg(:after, :string)
      complexity(&Pagination.complexity/2)
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Contracts.customers/3)
    end

    @desc "A team contract by ID."
    field :contract, :contract do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Contracts.contract/3)
    end

    @desc "A subscription by ID."
    field :subscription, :subscription_record do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Contracts.subscription/3)
    end

    @desc "Team subscriptions as a bounded cursor connection."
    field :subscriptions, :subscription_connection do
      arg(:team_id, non_null(:id))
      arg(:first, :integer)
      arg(:after, :string)
      complexity(&Pagination.complexity/2)
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Contracts.subscriptions/3)
    end

    @desc "A catalog product by ID."
    field :product, :product do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Catalog.product/3)
    end

    @desc "Team products as a bounded cursor connection."
    field :products, :product_connection do
      arg(:team_id, non_null(:id))
      arg(:first, :integer)
      arg(:after, :string)
      complexity(&Pagination.complexity/2)
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Catalog.products/3)
    end

    @desc "A plan by ID."
    field :plan, :plan do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Catalog.plan/3)
    end

    @desc "A plan version by ID (draft or published)."
    field :plan_version, :plan_version do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Catalog.plan_version/3)
    end

    @desc "A discount by ID."
    field :discount, :discount do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Catalog.discount/3)
    end

    @desc "An immutable invoice intent with lines and lifecycle state."
    field :invoice_intent, :invoice_intent do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Billing.invoice_intent/3)
    end

    @desc "Deterministic invoice preview for a subscription (BC-US-068)."
    field :invoice_preview, :invoice_preview do
      arg(:team_id, non_null(:id))
      arg(:subscription_id, non_null(:id))
      arg(:as_of, non_null(:date))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Billing.invoice_preview/3)
    end

    @desc "Usage aggregation preview for a metric over a period (BC-US-053)."
    field :usage_preview, :usage_aggregate do
      arg(:team_id, non_null(:id))
      arg(:subscription_id, non_null(:id))
      arg(:metric_code, non_null(:string))
      arg(:period_start, non_null(:date))
      arg(:period_end_exclusive, non_null(:date))
      arg(:cutoff, :datetime)
      arg(:aggregation, :string)
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Usage.usage_preview/3)
    end

    @desc "A billing run by ID."
    field :billing_run, :billing_run do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Billing.billing_run/3)
    end

    @desc "The team's ERP connection."
    field :erp_connection, :erp_connection do
      arg(:team_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Erp.erp_connection/3)
    end

    @desc "A durable operation by ID (team-scoped)."
    field :operation, :operation do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Erp.operation/3)
    end

    @desc "Pending and settled membership invitations of an organization (BC-US-144)."
    field :organization_invitations, non_null(list_of(non_null(:organization_invitation))) do
      arg(:organization_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.organization_invitations/3)
    end

    @desc "Active membership directory of an organization (owners/admins)."
    field :organization_memberships,
          non_null(list_of(non_null(:organization_membership_record))) do
      arg(:organization_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.organization_memberships/3)
    end

    @desc "Active membership directory of a team (any team member)."
    field :team_memberships, non_null(list_of(non_null(:team_membership_record))) do
      arg(:team_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.team_memberships/3)
    end

    @desc "Audit package for an invoice chain: canonical evidence files + checksum manifest (BC-US-114)."
    field :audit_export, :audit_export do
      arg(:team_id, non_null(:id))
      arg(:invoice_intent_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&BillingCoreWeb.GraphQL.Audit.Resolvers.audit_export/3)
    end

    @desc "Credit accounts linked to a customer, with subledger evidence (BC-US-107)."
    field :credit_accounts, non_null(list_of(non_null(:credit_account))) do
      arg(:team_id, non_null(:id))
      arg(:customer_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&Resolvers.Credits.credit_accounts/3)
    end

    @desc "One monthly customer-credit close (BC-US-163…165)."
    field :credit_close, :credit_close do
      arg(:team_id, non_null(:id))
      arg(:id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&CreditCloses.Resolvers.credit_close/3)
    end

    @desc "The team's monthly customer-credit closes, newest period first (max 100)."
    field :credit_closes, non_null(list_of(non_null(:credit_close))) do
      arg(:team_id, non_null(:id))
      arg(:currency, :string)
      arg(:state, :string)
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&CreditCloses.Resolvers.credit_closes/3)
    end

    @desc "The team's close posting-policy versions, newest first."
    field :credit_close_policies, non_null(list_of(non_null(:credit_close_policy))) do
      arg(:team_id, non_null(:id))
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&CreditCloses.Resolvers.credit_close_policies/3)
    end

    @desc "Receivable settlements opened by credit applications (SPEC §9.4.1)."
    field :credit_settlements, non_null(list_of(non_null(:credit_settlement))) do
      arg(:team_id, non_null(:id))
      arg(:invoice_intent_id, :id)
      arg(:state, :string)
      middleware(Middleware.RequireScope, mode: :query)
      resolve(&CreditCloses.Resolvers.credit_settlements/3)
    end
  end

  mutation do
    @desc "Ingests one usage event idempotently by external event ID (BC-US-050)."
    field :ingest_usage_event, non_null(:ingest_usage_event_result) do
      arg(:input, non_null(:ingest_usage_event_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Usage.ingest_usage_event/3)
    end

    @desc "Ingests usage events in a batch with per-event independence (BC-US-051)."
    field :ingest_usage_batch, non_null(:ingest_usage_batch_result) do
      arg(:input, non_null(:ingest_usage_batch_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Usage.ingest_usage_batch/3)
    end

    @desc "Voids a measurement, optionally submitting a replacement (BC-US-052)."
    field :void_usage_event, non_null(:void_usage_event_result) do
      arg(:input, non_null(:void_usage_event_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Usage.void_usage_event/3)
    end

    @desc "Creates an organization with its first team (INV-033)."
    field :create_organization, non_null(:create_organization_result) do
      arg(:input, non_null(:create_organization_input))
      resolve(&Resolvers.Orgs.create_organization/3)
    end

    @desc "Creates an additional team (organization admins)."
    field :create_team, non_null(:create_team_result) do
      arg(:input, non_null(:create_team_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Orgs.create_team/3)
    end

    @desc "Creates or updates a customer as an immutable version snapshot (BC-US-030)."
    field :upsert_customer, non_null(:upsert_customer_result) do
      arg(:input, non_null(:upsert_customer_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.upsert_customer/3)
    end

    @desc "Maps a customer to an ERP customer number (BC-US-031)."
    field :map_customer_to_erp, non_null(:map_customer_to_erp_result) do
      arg(:input, non_null(:map_customer_to_erp_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.map_customer_to_erp/3)
    end

    @desc "Maps a product to an ERP product number (BC-US-011)."
    field :map_product_to_erp, non_null(:map_product_to_erp_result) do
      arg(:input, non_null(:map_product_to_erp_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Catalog.map_product_to_erp/3)
    end

    @desc "Creates a product with its version 1 snapshot (BC-US-010)."
    field :create_product, non_null(:create_product_result) do
      arg(:input, non_null(:create_product_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Catalog.create_product/3)
    end

    @desc "Creates a plan (stable code owner, BC-US-013)."
    field :create_plan, non_null(:create_plan_result) do
      arg(:input, non_null(:create_plan_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Catalog.create_plan/3)
    end

    @desc "Creates a draft plan version with its components in one command."
    field :create_plan_version, non_null(:create_plan_version_result) do
      arg(:input, non_null(:create_plan_version_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Catalog.create_plan_version/3)
    end

    @desc "Publishes a draft plan version, making it immutable (BC-US-014)."
    field :publish_plan_version, non_null(:publish_plan_version_result) do
      arg(:input, non_null(:publish_plan_version_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Catalog.publish_plan_version/3)
    end

    @desc "Creates a contract with its immutable version 1 (BC-US-033)."
    field :create_contract, non_null(:create_contract_result) do
      arg(:input, non_null(:create_contract_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.create_contract/3)
    end

    @desc "Starts a subscription (BC-US-034/035, SPEC §14.9)."
    field :create_subscription, non_null(:create_subscription_result) do
      arg(:input, non_null(:create_subscription_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.create_subscription/3)
    end

    @desc "Changes a subscription's quantity by appending a version (BC-US-036)."
    field :change_subscription, non_null(:change_subscription_result) do
      arg(:input, non_null(:change_subscription_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.change_subscription/3)
    end

    @desc "Cancels a subscription immediately or at period end (BC-US-038)."
    field :cancel_subscription, non_null(:cancel_subscription_result) do
      arg(:input, non_null(:cancel_subscription_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.cancel_subscription/3)
    end

    @desc "Creates an idempotent one-time charge instance (BC-US-041)."
    field :create_charge_instance, non_null(:create_charge_instance_result) do
      arg(:input, non_null(:create_charge_instance_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Contracts.create_charge_instance/3)
    end

    @desc "Opens (or returns) a billing run by stable run key (SPEC §18.1)."
    field :create_billing_run, non_null(:create_billing_run_result) do
      arg(:input, non_null(:create_billing_run_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Billing.create_billing_run/3)
    end

    @desc "Freezes a subscription's preview into immutable invoice intent (BC-US-069)."
    field :freeze_invoice_intent, non_null(:freeze_invoice_intent_result) do
      arg(:input, non_null(:freeze_invoice_intent_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Billing.freeze_invoice_intent/3)
    end

    @desc "Replaces a frozen, unsynchronized intent in its chain (BC-US-100)."
    field :supersede_invoice_intent, non_null(:supersede_invoice_intent_result) do
      arg(:input, non_null(:supersede_invoice_intent_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Billing.supersede_invoice_intent/3)
    end

    @desc "Runs the ERP adapter preflight and records capabilities (BC-US-004)."
    field :validate_erp_connection, non_null(:validate_erp_connection_result) do
      arg(:input, non_null(:validate_erp_connection_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Erp.validate_erp_connection/3)
    end

    @desc "Enqueues ERP draft synchronization; follow the returned operation (§14.11)."
    field :synchronize_invoice, non_null(:synchronize_invoice_result) do
      arg(:input, non_null(:synchronize_invoice_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Erp.synchronize_invoice/3)
    end

    @desc "Approves a reconciled ERP draft for booking (BC-US-084)."
    field :approve_invoice, non_null(:approve_invoice_result) do
      arg(:input, non_null(:approve_invoice_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Erp.approve_invoice/3)
    end

    @desc "Enqueues booking of an approved draft (BC-US-085)."
    field :book_invoice, non_null(:book_invoice_result) do
      arg(:input, non_null(:book_invoice_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Erp.book_invoice/3)
    end

    @desc "Manually retries a failed durable operation (finance role, §11.3)."
    field :retry_operation, non_null(:retry_operation_result) do
      arg(:input, non_null(:retry_operation_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Erp.retry_operation/3)
    end

    @desc "Invites an email to organization/team memberships (BC-US-144)."
    field :invite_organization_member, non_null(:invite_organization_member_result) do
      arg(:input, non_null(:invite_organization_member_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.invite_organization_member/3)
    end

    @desc "Revokes a pending membership invitation (BC-US-144)."
    field :revoke_organization_invitation, non_null(:revoke_organization_invitation_result) do
      arg(:input, non_null(:revoke_organization_invitation_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.revoke_organization_invitation/3)
    end

    @desc "Replaces a member's organization roles; the last owner is protected (owners/admins)."
    field :change_organization_roles, non_null(:change_organization_roles_result) do
      arg(:input, non_null(:change_organization_roles_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.change_organization_roles/3)
    end

    @desc "Adds an existing organization member to a team (team admins, INV-024)."
    field :add_team_member, non_null(:add_team_member_result) do
      arg(:input, non_null(:add_team_member_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.add_team_member/3)
    end

    @desc "Replaces a team member's role grants (team admins)."
    field :change_team_roles, non_null(:change_team_roles_result) do
      arg(:input, non_null(:change_team_roles_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.change_team_roles/3)
    end

    @desc "Removes a member from a team; the history row is retained (team admins)."
    field :remove_team_member, non_null(:remove_team_member_result) do
      arg(:input, non_null(:remove_team_member_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.remove_team_member/3)
    end

    @desc "Renames a team; UUID and slug stay stable (team admins, BC-US-140)."
    field :rename_team, non_null(:rename_team_result) do
      arg(:input, non_null(:rename_team_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.rename_team/3)
    end

    @desc "Archives a team; the last active team is protected (owners/admins, INV-033)."
    field :archive_team, non_null(:archive_team_result) do
      arg(:input, non_null(:archive_team_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&BillingCoreWeb.GraphQL.Organizations.Resolvers.archive_team/3)
    end

    @desc "Grants customer credit into the subledger — a liability, never a discount (BC-US-107)."
    field :grant_credit, non_null(:grant_credit_result) do
      arg(:input, non_null(:grant_credit_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Credits.grant_credit/3)
    end

    @desc "Sets the versioned remaining-credit disposition policy (BC-US-109)."
    field :set_credit_disposition_policy, non_null(:set_credit_disposition_policy_result) do
      arg(:input, non_null(:set_credit_disposition_policy_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&Resolvers.Credits.set_disposition_policy/3)
    end

    @desc "Creates a monthly-close posting-policy version (BC-US-163)."
    field :create_credit_close_policy, non_null(:create_credit_close_policy_result) do
      arg(:input, non_null(:create_credit_close_policy_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.create_credit_close_policy/3)
    end

    @desc "Freezes one deterministic close for a currency and calendar month (BC-US-163)."
    field :generate_credit_close, non_null(:generate_credit_close_result) do
      arg(:input, non_null(:generate_credit_close_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.generate_credit_close/3)
    end

    @desc "Approves the exact frozen report hash for ERP posting (BC-US-164)."
    field :approve_credit_close, non_null(:approve_credit_close_result) do
      arg(:input, non_null(:approve_credit_close_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.approve_credit_close/3)
    end

    @desc "Creates the durable, idempotent ERP posting operation (BC-US-164)."
    field :request_credit_close_posting, non_null(:request_credit_close_posting_result) do
      arg(:input, non_null(:request_credit_close_posting_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.request_credit_close_posting/3)
    end

    @desc "Accepts a fully reconciled close as the authoritative period close (BC-US-165)."
    field :close_credit_period, non_null(:close_credit_period_result) do
      arg(:input, non_null(:close_credit_period_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.close_credit_period/3)
    end

    @desc "Freezes a compensating reversal close for an accepted close (ADR-031, BC-US-165)."
    field :request_credit_close_reversal, non_null(:request_credit_close_reversal_result) do
      arg(:input, non_null(:request_credit_close_reversal_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.request_credit_close_reversal/3)
    end

    @desc "Freezes a replacement close for a reversed period under a corrected policy (ADR-031)."
    field :generate_credit_close_replacement,
          non_null(:generate_credit_close_replacement_result) do
      arg(:input, non_null(:generate_credit_close_replacement_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.generate_credit_close_replacement/3)
    end

    @desc "Records the external receivables system's settlement reference exactly once (SPEC §9.4.1)."
    field :record_external_settlement, non_null(:record_external_settlement_result) do
      arg(:input, non_null(:record_external_settlement_input))
      middleware(Middleware.RequireScope, mode: :mutation)
      resolve(&CreditCloses.Resolvers.record_external_settlement/3)
    end
  end
end
