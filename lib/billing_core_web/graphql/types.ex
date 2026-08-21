defmodule BillingCoreWeb.GraphQL.Types do
  @moduledoc """
  Shared GraphQL types: typed mutation problems (SPEC §14.4), pagination
  (SPEC §14.6), durable operations, and the organization/membership graph.
  Business mutations return unions of a success payload and these problem
  types — expected business validation is never encoded as free-form error
  strings.
  """

  use Absinthe.Schema.Notation

  alias BillingCoreWeb.GraphQL.Errors
  alias BillingCoreWeb.GraphQL.Resolvers

  ## Typed mutation problems (SPEC §14.4)

  object :field_problem do
    field :path, non_null(list_of(non_null(:string)))
    field :code, non_null(:string)
    field :message, non_null(:string)
  end

  object :validation_problem do
    field :code, non_null(:string)
    field :message, non_null(:string)
    field :fields, non_null(list_of(non_null(:field_problem)))
    field :client_mutation_id, :string
  end

  object :mapping_problem do
    description("Missing/invalid ERP mappings or other unmet preconditions (SPEC §14.11).")
    field :code, non_null(:string)
    field :message, non_null(:string)
    field :fields, non_null(list_of(non_null(:field_problem)))
    field :client_mutation_id, :string
  end

  object :authorization_problem do
    field :code, non_null(:string)
    field :message, non_null(:string)
    field :client_mutation_id, :string
  end

  object :version_conflict do
    field :expected_version, :integer
    field :actual_version, :integer
    field :client_mutation_id, :string
  end

  object :idempotency_conflict do
    description("The idempotency key was reused with materially different input.")
    field :code, non_null(:string)
    field :message, non_null(:string)
    field :client_mutation_id, :string
  end

  ## Pagination (SPEC §14.6)

  object :page_info do
    field :has_next_page, non_null(:boolean)
    field :end_cursor, :string
  end

  ## Durable operations (SPEC §22.9.2, §14.11)

  @desc "Durable asynchronous operation; clients follow it instead of HTTP 202 semantics."
  object :operation do
    field :id, non_null(:id)
    field :type, non_null(:string)
    field :state, non_null(:string)
    field :attempt_count, non_null(:integer)
    field :error_class, :string
    field :safe_error_code, :string
    field :safe_error_summary, :string
    field :blocked_reason, :string
    field :next_attempt_at, :datetime
    field :correlation_id, :id
    field :started_at, :datetime
    field :finished_at, :datetime
  end

  ## Viewer / organizations / teams (SPEC §14.5 organizations and membership)

  @desc "The authenticated principal and its memberships."
  object :viewer do
    field :id, non_null(:id)
    field :status, non_null(:string)
    field :platform_admin, non_null(:boolean)

    field :organization_memberships,
          non_null(list_of(non_null(:viewer_organization_membership))) do
      resolve(&Resolvers.Orgs.organization_memberships/3)
    end

    field :team_memberships, non_null(list_of(non_null(:viewer_team_membership))) do
      resolve(&Resolvers.Orgs.team_memberships/3)
    end
  end

  object :organization do
    field :id, non_null(:id)
    field :name, non_null(:string)
    field :slug, non_null(:string)
    field :status, non_null(:string)
  end

  object :team do
    field :id, non_null(:id)
    field :organization_id, non_null(:id)
    field :name, non_null(:string)
    field :slug, non_null(:string)
    field :legal_name, :string
    field :base_currency, non_null(:string)
    field :time_zone, non_null(:string)
    field :locale, non_null(:string)
    field :status, non_null(:string)
  end

  object :viewer_organization_membership do
    field :organization, non_null(:organization)
    field :roles, non_null(list_of(non_null(:string)))
  end

  object :viewer_team_membership do
    field :team, non_null(:team)
    field :roles, non_null(list_of(non_null(:string)))
  end

  ## createOrganization

  input_object :create_organization_input do
    field :name, non_null(:string)
    field :team_name, :string
    field :legal_name, :string
    field :base_currency, :string
    field :time_zone, :string
    field :locale, :string
    field :client_mutation_id, non_null(:string)
  end

  object :create_organization_success do
    field :organization, non_null(:organization)
    field :team, non_null(:team)
    field :client_mutation_id, non_null(:string)
  end

  union :create_organization_result do
    types([:create_organization_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_organization_success)
    end)
  end

  ## createTeam

  input_object :create_team_input do
    field :organization_id, non_null(:id)
    field :name, non_null(:string)
    field :legal_name, :string
    field :base_currency, :string
    field :time_zone, :string
    field :locale, :string
    field :client_mutation_id, non_null(:string)
  end

  object :create_team_success do
    field :team, non_null(:team)
    field :client_mutation_id, non_null(:string)
  end

  union :create_team_result do
    types([:create_team_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :create_team_success)
    end)
  end

  ## retryOperation

  input_object :retry_operation_input do
    field :team_id, non_null(:id)
    field :operation_id, non_null(:id)
    field :client_mutation_id, non_null(:string)
  end

  object :retry_operation_success do
    field :operation, non_null(:operation)
    field :client_mutation_id, non_null(:string)
  end

  union :retry_operation_result do
    types([:retry_operation_success, :validation_problem, :authorization_problem])

    resolve_type(fn value, _ ->
      Errors.resolve_union(value, :retry_operation_success)
    end)
  end
end
