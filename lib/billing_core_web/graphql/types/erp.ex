defmodule BillingCoreWeb.GraphQL.Types.Erp do
  @moduledoc """
  ERP connections and synchronization/approval/booking commands
  (SPEC §14.5 ERP operations capability group, §14.11).
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors

  ## Objects

  object :erp_connection do
    field :id, non_null(:id)
    field :provider, non_null(:string)
    field :status, non_null(:string)
    field :external_agreement_id, :string
    field :capabilities_hash, :string
    field :last_validated_at, :datetime
  end

  ## validateErpConnection

  input_object :validate_erp_connection_input do
    field :team_id, non_null(:id)
    field :erp_connection_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :validate_erp_connection_success do
    field :erp_connection, non_null(:erp_connection)
    field :client_mutation_id, non_null(:string)
  end

  union :validate_erp_connection_result do
    types([:validate_erp_connection_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :validate_erp_connection_success)
    end)
  end

  ## synchronizeInvoice (SPEC §14.11)

  input_object :synchronize_invoice_input do
    field :team_id, non_null(:id)
    field :invoice_intent_id, non_null(:id)
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :synchronize_invoice_accepted do
    @desc "Durable operation to follow; work continues asynchronously."
    field :operation, non_null(:operation)
    field :client_mutation_id, non_null(:string)
  end

  union :synchronize_invoice_result do
    types([
      :synchronize_invoice_accepted,
      :mapping_problem,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :synchronize_invoice_accepted)
    end)
  end

  ## approveInvoice

  input_object :approve_invoice_input do
    field :team_id, non_null(:id)
    field :invoice_intent_id, non_null(:id)
    field :reason, :string
    field :client_mutation_id, non_null(:string)
  end

  object :approve_invoice_success do
    field :invoice_intent, non_null(:invoice_intent)
    field :client_mutation_id, non_null(:string)
  end

  union :approve_invoice_result do
    types([:approve_invoice_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :approve_invoice_success)
    end)
  end

  ## bookInvoice

  input_object :book_invoice_input do
    field :team_id, non_null(:id)
    field :invoice_intent_id, non_null(:id)
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :book_invoice_accepted do
    @desc "Durable booking operation to follow."
    field :operation, non_null(:operation)
    field :client_mutation_id, non_null(:string)
  end

  union :book_invoice_result do
    types([
      :book_invoice_accepted,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :book_invoice_accepted)
    end)
  end
end
