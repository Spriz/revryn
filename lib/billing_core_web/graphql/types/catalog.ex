defmodule BillingCoreWeb.GraphQL.Types.Catalog do
  @moduledoc """
  Products, plans, plan versions, price components, and discounts
  (SPEC §14.5 catalog + discounts capability groups).
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors

  ## Objects

  object :product do
    field :id, non_null(:id)
    field :code, non_null(:string)
    field :name, non_null(:string)
    field :description, :string
    field :status, non_null(:string)
    field :recognition_mode, :string
    field :current_version, non_null(:integer)
  end

  object :product_edge do
    field :cursor, non_null(:string)
    field :node, non_null(:product)
  end

  object :product_connection do
    field :edges, non_null(list_of(non_null(:product_edge)))
    field :page_info, non_null(:page_info)
  end

  object :plan do
    field :id, non_null(:id)
    field :code, non_null(:string)
    field :name, non_null(:string)
    field :status, non_null(:string)

    @desc "Highest published version; 0 while no version is published."
    field :current_version, non_null(:integer)
  end

  object :plan_version do
    field :id, non_null(:id)
    field :plan_id, non_null(:id)
    field :version, non_null(:integer)
    field :status, non_null(:string)
    field :currency, non_null(:string)
    field :interval_unit, non_null(:string)
    field :interval_count, non_null(:integer)
    field :billing_timing, non_null(:string)
    field :effective_from, :date
    field :content_hash, :string
    field :published_at, :datetime

    field :price_components, non_null(list_of(non_null(:price_component))) do
      resolve(&BillingCoreWeb.GraphQL.Resolvers.Catalog.price_components/3)
    end
  end

  object :price_component do
    field :id, non_null(:id)
    field :code, non_null(:string)
    field :product_id, non_null(:id)
    field :product_version, :integer
    field :pricing_model, non_null(:string)
    field :recognition_mode, non_null(:string)
    field :proration_policy, non_null(:string)
    field :ordinal, non_null(:integer)
  end

  object :discount do
    field :id, non_null(:id)
    field :code, non_null(:string)
    field :status, non_null(:string)
    field :current_version, non_null(:integer)
  end

  ## createProduct

  input_object :create_product_input do
    field :team_id, non_null(:id)
    field :code, non_null(:string)
    field :name, non_null(:string)
    field :description, :string
    field :recognition_mode, :recognition_mode
    field :service_period_source, :string
    field :client_mutation_id, non_null(:string)
  end

  object :create_product_success do
    field :product, non_null(:product)
    field :client_mutation_id, non_null(:string)
  end

  union :create_product_result do
    types([:create_product_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_product_success)
    end)
  end

  ## createPlan

  input_object :create_plan_input do
    field :team_id, non_null(:id)
    field :code, non_null(:string)
    field :name, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :create_plan_success do
    field :plan, non_null(:plan)
    field :client_mutation_id, non_null(:string)
  end

  union :create_plan_result do
    types([:create_plan_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_plan_success)
    end)
  end

  ## createPlanVersion (draft + components in one command)

  enum :interval_unit do
    value(:month)
    value(:day)
  end

  enum :billing_timing do
    value(:in_advance)
    value(:in_arrears)
  end

  @desc "Versioned pricing definition; exactly one model group is set (SPEC §9.6)."
  input_object :pricing_definition_input do
    field :fixed_recurring, :fixed_recurring_pricing_input
    field :one_time, :one_time_pricing_input
    field :standard_metered, :standard_metered_pricing_input
    field :volume_tier, :tiered_pricing_input
    field :graduated_tier, :tiered_pricing_input
    field :package, :package_pricing_input
    field :minimum_commit, :minimum_commit_pricing_input
  end

  input_object :fixed_recurring_pricing_input do
    @desc "Unit price per interval in major currency units."
    field :unit_price, non_null(:decimal)
  end

  input_object :one_time_pricing_input do
    field :unit_price, non_null(:decimal)
  end

  input_object :standard_metered_pricing_input do
    @desc "Per-unit rate in major currency units."
    field :unit_rate, non_null(:decimal)
  end

  @desc "Contiguous tier: half-open [from, to); the final tier omits `to` (SPEC §10.3/10.4)."
  input_object :pricing_tier_input do
    field :from, non_null(:decimal)
    field :to, :decimal
    field :unit_rate, non_null(:decimal)
    field :flat_fee_minor, :money_minor_units
  end

  input_object :tiered_pricing_input do
    field :tiers, non_null(list_of(non_null(:pricing_tier_input)))
  end

  input_object :package_pricing_input do
    field :package_size, non_null(:decimal)
    @desc "Price per whole package in major currency units."
    field :package_price, non_null(:decimal)
  end

  @desc "Minimum commit wrapping an inner usage model (SPEC §10.6)."
  input_object :minimum_commit_pricing_input do
    field :minimum_amount_minor, non_null(:money_minor_units)
    field :inner, non_null(:pricing_definition_input)
  end

  input_object :price_component_input do
    field :code, non_null(:string)
    field :product_id, non_null(:id)
    field :pricing_definition, non_null(:pricing_definition_input)
    field :proration_policy, :string
    field :ordinal, :integer

    @desc "Required for metered models: the usage metric this component rates."
    field :metric_code, :string
    field :aggregation, :string, description: "sum | count | max | unique_count"
  end

  input_object :create_plan_version_input do
    field :team_id, non_null(:id)
    field :plan_id, non_null(:id)
    field :currency, non_null(:string)
    field :interval_unit, non_null(:interval_unit)
    field :interval_count, non_null(:integer)
    field :billing_timing, non_null(:billing_timing)
    field :effective_from, :date
    field :components, non_null(list_of(non_null(:price_component_input)))
    field :client_mutation_id, non_null(:string)
  end

  object :create_plan_version_success do
    field :plan_version, non_null(:plan_version)
    field :client_mutation_id, non_null(:string)
  end

  union :create_plan_version_result do
    types([:create_plan_version_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_plan_version_success)
    end)
  end

  ## publishPlanVersion

  input_object :publish_plan_version_input do
    field :team_id, non_null(:id)
    field :plan_version_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :publish_plan_version_success do
    field :plan_version, non_null(:plan_version)
    field :client_mutation_id, non_null(:string)
  end

  union :publish_plan_version_result do
    types([:publish_plan_version_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :publish_plan_version_success)
    end)
  end

  ## mapProductToErp (BC-US-011)

  object :product_erp_mapping do
    field :id, non_null(:id)
    field :product_id, non_null(:id)
    field :erp_connection_id, non_null(:id)
    field :external_product_number, non_null(:string)
    field :validation_status, non_null(:string)
  end

  input_object :map_product_to_erp_input do
    field :team_id, non_null(:id)
    field :product_id, non_null(:id)
    field :erp_connection_id, non_null(:id)
    field :external_product_number, non_null(:string)
    field :client_mutation_id, non_null(:string)
  end

  object :map_product_to_erp_success do
    field :mapping, non_null(:product_erp_mapping)
    field :client_mutation_id, non_null(:string)
  end

  union :map_product_to_erp_result do
    types([:map_product_to_erp_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :map_product_to_erp_success)
    end)
  end
end
