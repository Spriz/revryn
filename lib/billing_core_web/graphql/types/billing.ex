defmodule BillingCoreWeb.GraphQL.Types.Billing do
  @moduledoc """
  Billing runs, invoice preview, and immutable invoice intent (SPEC §14.5
  billing capability group, §11.2, BC-US-068/069/100).
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors
  alias BillingCoreWeb.GraphQL.Resolvers

  ## Objects

  object :billing_run do
    field :id, non_null(:id)
    field :run_key, non_null(:string)
    field :status, non_null(:string)
    field :invoice_date, non_null(:date)
    field :usage_cutoff, non_null(:datetime)
    field :engine_version, non_null(:string)
    field :started_at, :datetime
    field :closed_at, :datetime
  end

  object :invoice_line do
    field :id, non_null(:id)
    field :line_key, non_null(:string)
    field :description, non_null(:string)
    field :quantity, non_null(:decimal)
    field :amount_minor, non_null(:money_minor_units)
    field :currency, non_null(:string)
    field :recognition_mode, non_null(:string)
    field :service_start, :date
    field :service_end_exclusive, :date
    field :ordinal, non_null(:integer)
    field :product_id, non_null(:id)
    field :product_version, non_null(:integer)
  end

  @desc "Immutable frozen invoice intent plus its mutable lifecycle state (§11.2)."
  object :invoice_intent do
    field :id, non_null(:id)

    @desc "Current §11.2 lifecycle state (frozen, sync_pending, erp_draft, ...)."
    field :state, non_null(:string) do
      resolve(&Resolvers.Billing.intent_state/3)
    end

    field :customer_id, non_null(:id)
    field :customer_version, non_null(:integer)
    field :contract_id, :id
    field :billing_run_id, :id
    field :currency, non_null(:string)
    field :invoice_date, non_null(:date)
    field :intent_version, non_null(:integer)
    field :supersedes_invoice_intent_id, :id
    field :document_kind, non_null(:string)
    field :content_hash, non_null(:string)
    field :net_amount_minor, non_null(:money_minor_units)
    field :frozen_at, :datetime

    field :lines, non_null(list_of(non_null(:invoice_line))) do
      resolve(&Resolvers.Billing.intent_lines/3)
    end
  end

  @desc "Deterministic, side-effect-free invoice preview (BC-US-068)."
  object :invoice_preview do
    field :subscription_id, non_null(:id)
    field :customer_id, non_null(:id)
    field :contract_id, non_null(:id)
    field :currency, non_null(:string)
    field :invoice_date, non_null(:date)
    field :period_start, non_null(:date)
    field :period_end_exclusive, non_null(:date)
    field :net_amount_minor, non_null(:money_minor_units)

    @desc "Stable for unchanged inputs; freezing verifies against this."
    field :fingerprint, non_null(:string)

    @desc "Stable-coded conditions preventing freeze; empty means freezable."
    field :blockers, non_null(list_of(non_null(:string)))

    field :lines, non_null(list_of(non_null(:preview_line)))
  end

  object :preview_line do
    field :line_key, non_null(:string)
    field :description, non_null(:string)
    field :quantity, non_null(:decimal)
    field :amount_minor, non_null(:money_minor_units)
    field :recognition_mode, non_null(:string)
    field :service_start, :date
    field :service_end_exclusive, :date
    field :ordinal, non_null(:integer)
    field :product_id, non_null(:id)
  end

  ## createBillingRun

  input_object :create_billing_run_input do
    field :team_id, non_null(:id)

    @desc "Stable run key; reopening the same key returns the existing run."
    field :run_key, non_null(:string)
    field :invoice_date, non_null(:date)
    field :usage_cutoff, non_null(:datetime)
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :create_billing_run_success do
    field :billing_run, non_null(:billing_run)
    field :client_mutation_id, non_null(:string)
  end

  union :create_billing_run_result do
    types([
      :create_billing_run_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_billing_run_success)
    end)
  end

  ## freezeInvoiceIntent

  input_object :freeze_invoice_intent_input do
    field :team_id, non_null(:id)
    field :subscription_id, non_null(:id)

    @desc "The preview date; the billing period containing it is frozen."
    field :as_of, non_null(:date)
    field :billing_run_id, :id
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :freeze_invoice_intent_success do
    field :invoice_intent, non_null(:invoice_intent)
    field :client_mutation_id, non_null(:string)
  end

  union :freeze_invoice_intent_result do
    types([
      :freeze_invoice_intent_success,
      :validation_problem,
      :mapping_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :freeze_invoice_intent_success)
    end)
  end

  ## supersedeInvoiceIntent

  input_object :supersede_invoice_intent_input do
    field :team_id, non_null(:id)
    field :invoice_intent_id, non_null(:id)
    field :subscription_id, non_null(:id)

    @desc "Preview date for the replacement intent's lines."
    field :as_of, non_null(:date)
    field :reason, :string
    field :client_mutation_id, non_null(:string)
  end

  object :supersede_invoice_intent_success do
    @desc "The replacement intent (intentVersion incremented, same chain)."
    field :invoice_intent, non_null(:invoice_intent)
    field :client_mutation_id, non_null(:string)
  end

  union :supersede_invoice_intent_result do
    types([
      :supersede_invoice_intent_success,
      :validation_problem,
      :mapping_problem,
      :authorization_problem
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :supersede_invoice_intent_success)
    end)
  end
end
