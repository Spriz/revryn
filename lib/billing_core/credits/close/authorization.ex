defmodule BillingCore.Credits.Close.Authorization do
  @moduledoc "Team-scoped authorization checks for close commands and evidence reads."

  alias BillingCore.Scope

  @write_roles [:finance_operator, :billing_admin, :team_admin]
  @read_roles @write_roles ++ [:auditor, :integration_client]

  @spec authorize(Scope.t(), map(), :read | :write) :: :ok | {:error, :unauthorized}
  def authorize(%Scope{} = scope, %{team_id: team_id}, action) when action in [:read, :write] do
    roles = if action == :write, do: @write_roles, else: @read_roles

    if Scope.team_scoped?(scope) and Scope.team_id!(scope) == team_id and
         Scope.has_team_role?(scope, roles) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def authorize(_, _, _), do: {:error, :unauthorized}
end
