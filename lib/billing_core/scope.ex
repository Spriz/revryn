defmodule BillingCore.Scope do
  @moduledoc """
  Resolved authorization scope threaded through every context call
  (SPEC §13.4, INV-024/025, Phoenix 1.8 scope pattern).

  A scope is built by the authentication/authorization pipeline — never from
  raw request parameters. It carries the authenticated principal plus the
  explicitly resolved current organization and team and the membership roles
  in each. Possession of an ID never grants access; context functions must
  authorize against this scope and constrain queries by
  `scope.team.id` / `scope.organization.id`.

  `principal_type` distinguishes human users from machine service credentials
  (`:service`), which carry explicit capability grants instead of memberships.
  """

  @enforce_keys [:principal_type]
  defstruct principal_type: :user,
            user: nil,
            service_credential: nil,
            organization: nil,
            team: nil,
            organization_roles: [],
            team_roles: [],
            platform_admin?: false,
            correlation_id: nil

  @type organization_role :: :organization_owner | :organization_admin | :organization_member
  @type team_role ::
          :team_admin | :billing_admin | :finance_operator | :auditor | :integration_client

  @type t :: %__MODULE__{
          principal_type: :user | :service,
          user: struct() | nil,
          service_credential: struct() | nil,
          organization: struct() | nil,
          team: struct() | nil,
          organization_roles: [organization_role()],
          team_roles: [team_role()],
          platform_admin?: boolean(),
          correlation_id: String.t() | nil
        }

  @doc "True when the scope has a resolved team."
  @spec team_scoped?(t()) :: boolean()
  def team_scoped?(%__MODULE__{team: team}), do: not is_nil(team)

  @spec has_team_role?(t(), team_role() | [team_role()]) :: boolean()
  def has_team_role?(%__MODULE__{team_roles: roles}, wanted) when is_list(wanted) do
    Enum.any?(wanted, &(&1 in roles))
  end

  def has_team_role?(%__MODULE__{team_roles: roles}, wanted), do: wanted in roles

  @spec has_organization_role?(t(), organization_role() | [organization_role()]) :: boolean()
  def has_organization_role?(%__MODULE__{organization_roles: roles}, wanted)
      when is_list(wanted) do
    Enum.any?(wanted, &(&1 in roles))
  end

  def has_organization_role?(%__MODULE__{organization_roles: roles}, wanted), do: wanted in roles

  @doc "Team ID for query scoping; raises when the scope is not team-resolved."
  @spec team_id!(t()) :: Ecto.UUID.t()
  def team_id!(%__MODULE__{team: %{id: id}}) when not is_nil(id), do: id

  def team_id!(%__MODULE__{}) do
    raise ArgumentError, "operation requires a team-resolved scope"
  end

  @spec organization_id!(t()) :: Ecto.UUID.t()
  def organization_id!(%__MODULE__{organization: %{id: id}}) when not is_nil(id), do: id

  def organization_id!(%__MODULE__{}) do
    raise ArgumentError, "operation requires an organization-resolved scope"
  end
end
