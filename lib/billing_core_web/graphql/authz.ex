defmodule BillingCoreWeb.GraphQL.Authz do
  @moduledoc """
  Field-level role checks for resolvers that perform read-only listing
  queries the domain contexts do not expose (SPEC §14.2: authorization is
  enforced in resolver middleware *and* domain command handlers — commands
  always re-check inside their context).
  """

  alias BillingCore.Scope

  @read_roles [:team_admin, :billing_admin, :finance_operator, :auditor, :integration_client]
  @finance_roles [:finance_operator]

  @doc "True when the team-resolved scope may read team billing data."
  @spec can_read?(Scope.t()) :: boolean()
  def can_read?(%Scope{} = scope), do: Scope.has_team_role?(scope, @read_roles)

  @doc "True when the scope holds a finance role (ERP command surface)."
  @spec finance?(Scope.t()) :: boolean()
  def finance?(%Scope{} = scope), do: Scope.has_team_role?(scope, @finance_roles)

  @doc "Principal identifier stored as idempotency evidence (SPEC §14.3)."
  @spec principal_id(Scope.t()) :: String.t() | nil
  def principal_id(%Scope{user: %{id: id}}), do: "user:#{id}"
  def principal_id(%Scope{service_credential: %{id: id}}), do: "service:#{id}"
  def principal_id(%Scope{}), do: nil
end
