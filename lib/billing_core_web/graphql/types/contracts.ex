defmodule BillingCoreWeb.GraphQL.Types.Contracts do
  @moduledoc """
  Customers, contracts, subscriptions, and charge instances (SPEC §14.5
  accounts/customers + contracts/subscriptions capability groups).
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors
  alias BillingCoreWeb.GraphQL.Resolvers

  ## Objects

  object :customer do
    field :id, non_null(:id)
    field :external_id, non_null(:string)
    field :status, non_null(:string)
    field :current_version, non_null(:integer)

    @desc "Legal name from the current immutable customer version snapshot."
    field :legal_name, :string do
      resolve(&Resolvers.Contracts.customer_legal_name/3)
    end
  end

  object :customer_edge do
    field :cursor, non_null(:string)
    field :node, non_null(:customer)
  end

  object :customer_connection do
    field :edges, non_null(list_of(non_null(:customer_edge)))
    field :page_info, non_null(:page_info)
  end

  object :customer_erp_mapping do
    field :id, non_null(:id)
    field :customer_id, non_null(:id)
    field :erp_connection_id, non_null(:id)
    field :external_customer_number, non_null(:string)
    field :validation_status, non_null(:string)
  end

  object :contract do
    field :id, non_null(:id)
    field :customer_id, non_null(:id)
    field :external_reference, :string
    field :status, non_null(:string)
    field :currency, non_null(:string)
    field :start_date, non_null(:date)
    field :end_date_exclusive, :date
    field :current_version, non_null(:integer)
  end

  object :subscription_record, name: "Subscription" do
    description("A contract subscription (SPEC §11.1 lifecycle).")
    field :id, non_null(:id)
    field :external_id, non_null(:string)
    field :contract_id, non_null(:id)

    @desc "§11.1 lifecycle state."
    field :state, non_null(:string) do
      resolve(fn subscription, _, _ -> {:ok, to_string(subscription.status)} end)
    end

    field :starts_on, non_null(:date) do
      resolve(fn subscription, _, _ -> {:ok, subscription.start_date} end)
    end

    field :end_date_exclusive, :date
    field :billing_anchor_day, :integer
    field :time_zone, non_null(:string)

    @desc "Optimistic-concurrency version of the aggregate (SPEC §14.3)."
    field :version, non_null(:integer)
    field :current_version, non_null(:integer)
  end

  object :subscription_edge do
    field :cursor, non_null(:string)
    field :node, non_null(:subscription_record)
  end

  object :subscription_connection do
    field :edges, non_null(list_of(non_null(:subscription_edge)))
    field :page_info, non_null(:page_info)
  end

  object :charge_instance do
    field :id, non_null(:id)
    field :external_id, non_null(:string)
    field :contract_id, non_null(:id)
    field :subscription_id, :id
    field :status, non_null(:string)
    field :eligible_on, non_null(:date)
    field :quantity, :decimal
    field :amount_minor, :money_minor_units
    field :currency, non_null(:string)
    field :recognition_mode, non_null(:string)
    field :service_start, :date
    field :service_end_exclusive, :date
  end

  ## upsertCustomer

  input_object :upsert_customer_input do
    field :team_id, non_null(:id)
    field :external_id, non_null(:string)
    field :legal_name, non_null(:string)
    field :country, non_null(:string)
    field :email, non_null(:string)
    field :address_line, :string
    field :zip, :string
    field :city, :string
    field :vat_number, :string
    field :currency_preference, :string

    @desc "Optimistic concurrency against the customer's currentVersion."
    field :expected_version, :integer
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :upsert_customer_success do
    field :customer, non_null(:customer)
    field :client_mutation_id, non_null(:string)
  end

  union :upsert_customer_result do
    types([
      :upsert_customer_success,
      :validation_problem,
      :authorization_problem,
      :version_conflict,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :upsert_customer_success)
    end)
  end

  ## mapCustomerToErp

  input_object :map_customer_to_erp_input do
    field :team_id, non_null(:id)
    field :customer_id, non_null(:id)
    field :erp_connection_id, non_null(:id)
    field :external_customer_number, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :map_customer_to_erp_success do
    field :mapping, non_null(:customer_erp_mapping)
    field :client_mutation_id, non_null(:string)
  end

  union :map_customer_to_erp_result do
    types([:map_customer_to_erp_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :map_customer_to_erp_success)
    end)
  end

  ## createContract

  input_object :create_contract_input do
    field :team_id, non_null(:id)
    field :customer_id, non_null(:id)
    field :external_reference, :string
    field :currency, non_null(:string)
    field :start_date, non_null(:date)
    field :end_date_exclusive, :date
    field :client_mutation_id, non_null(:string)
  end

  object :create_contract_success do
    field :contract, non_null(:contract)
    field :client_mutation_id, non_null(:string)
  end

  union :create_contract_result do
    types([:create_contract_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_contract_success)
    end)
  end

  ## createSubscription (SPEC §14.3/§14.9)

  input_object :create_subscription_input do
    field :team_id, non_null(:id)
    field :contract_id, non_null(:id)
    field :external_id, non_null(:string)
    field :plan_version_id, non_null(:id)
    field :starts_on, non_null(:date)
    field :end_date_exclusive, :date
    field :billing_anchor_day, :integer
    field :quantity, non_null(:decimal)
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :create_subscription_success do
    field :subscription, non_null(:subscription_record)
    field :client_mutation_id, non_null(:string)
  end

  union :create_subscription_result do
    types([
      :create_subscription_success,
      :validation_problem,
      :authorization_problem,
      :version_conflict,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_subscription_success)
    end)
  end

  ## changeSubscription (quantity)

  input_object :change_subscription_input do
    field :team_id, non_null(:id)
    field :subscription_id, non_null(:id)
    field :quantity, non_null(:decimal)

    @desc "Defaults to today in the subscription's time zone."
    field :effective_date, :date
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :change_subscription_success do
    field :subscription, non_null(:subscription_record)
    field :client_mutation_id, non_null(:string)
  end

  union :change_subscription_result do
    types([
      :change_subscription_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :change_subscription_success)
    end)
  end

  ## cancelSubscription

  enum :cancellation_mode do
    value(:immediate)
    value(:end_of_period)
  end

  input_object :cancel_subscription_input do
    field :team_id, non_null(:id)
    field :subscription_id, non_null(:id)
    field :mode, non_null(:cancellation_mode)
    field :effective_date, :date

    @desc "Required for END_OF_PERIOD: the period boundary computed by billing."
    field :period_end_date, :date
    field :reason, :string
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :cancel_subscription_success do
    field :subscription, non_null(:subscription_record)
    field :client_mutation_id, non_null(:string)
  end

  union :cancel_subscription_result do
    types([
      :cancel_subscription_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :cancel_subscription_success)
    end)
  end

  ## createChargeInstance

  enum :recognition_mode do
    value(:point_in_time)
    value(:over_time)
  end

  input_object :create_charge_instance_input do
    field :team_id, non_null(:id)
    field :contract_id, non_null(:id)
    field :subscription_id, :id
    field :external_id, non_null(:string)
    field :product_id, non_null(:id)
    field :product_version, non_null(:integer)
    field :eligible_on, non_null(:date)
    field :recognition_mode, non_null(:recognition_mode)

    @desc "Pricing source A: explicit amount in minor units (quantity fixed at 1)."
    field :amount_minor, :money_minor_units

    @desc "Pricing source B: a price component with a positive quantity."
    field :price_component_id, :id
    field :quantity, :decimal

    field :currency, :string
    field :service_start, :date
    field :service_end_exclusive, :date
    field :idempotency_key, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :create_charge_instance_success do
    field :charge_instance, non_null(:charge_instance)
    field :client_mutation_id, non_null(:string)
  end

  union :create_charge_instance_result do
    types([
      :create_charge_instance_success,
      :validation_problem,
      :authorization_problem,
      :idempotency_conflict
    ])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_charge_instance_success)
    end)
  end
end
