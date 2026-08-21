defmodule BillingCoreWeb.GraphQL.Resolvers.Orgs do
  @moduledoc """
  Viewer, organization, team, and membership resolvers (SPEC §14.5
  organizations and membership).

  Reads that the `Orgs` context does not expose (a user's own membership
  listing) are read-only queries constrained by the authenticated user.
  """

  import Ecto.Query

  alias BillingCore.{Orgs, Repo, Scope}
  alias BillingCore.Orgs.{Organization, OrganizationMembership, Team, TeamMembership}
  alias BillingCoreWeb.GraphQL.Errors

  ## Queries

  def viewer(_parent, _args, %{context: %{current_user: nil}}), do: Errors.unauthenticated()

  def viewer(_parent, _args, %{context: %{current_user: user}}) do
    {:ok, user}
  end

  def organization_memberships(user, _args, _resolution) do
    {:ok,
     Repo.all(
       from m in OrganizationMembership,
         join: o in Organization,
         on: o.id == m.organization_id,
         where: m.user_id == ^user.id and m.status == :active,
         order_by: [asc: o.name, asc: o.id],
         select: %{organization: o, roles: m.roles}
     )
     |> Enum.map(&stringify_roles/1)}
  end

  def team_memberships(user, _args, _resolution) do
    {:ok,
     Repo.all(
       from m in TeamMembership,
         join: t in Team,
         on: t.id == m.team_id,
         where: m.user_id == ^user.id and m.status == :active,
         order_by: [asc: t.name, asc: t.id],
         select: %{team: t, roles: m.roles}
     )
     |> Enum.map(&stringify_roles/1)}
  end

  def organizations(_parent, _args, %{context: %{current_user: nil}}),
    do: Errors.unauthenticated()

  def organizations(_parent, _args, %{context: %{current_user: user}}) do
    {:ok,
     Repo.all(
       from o in Organization,
         join: m in OrganizationMembership,
         on: m.organization_id == o.id,
         where: m.user_id == ^user.id and m.status == :active and o.status == :active,
         order_by: [asc: o.name, asc: o.id]
     )}
  end

  @doc "Single organization; requires an active membership (scope middleware)."
  def organization(_parent, _args, %{context: %{scope: %Scope{organization: organization}}}) do
    {:ok, organization}
  end

  @doc "Single team resolved through scope (teamId argument)."
  def team(_parent, _args, %{context: %{scope: %Scope{team: team}}}) do
    {:ok, team}
  end

  @doc "Active teams of an organization the caller belongs to."
  def teams(_parent, _args, %{context: %{scope: %Scope{organization: organization}}}) do
    {:ok, Orgs.list_active_teams(organization)}
  end

  ## Mutations

  def create_organization(_parent, %{input: input}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, Errors.authorization(input.client_mutation_id)}

      user ->
        attrs =
          input
          |> Map.take([:name, :team_name, :legal_name, :base_currency, :time_zone, :locale])
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case Orgs.create_organization(attrs, user) do
          {:ok, %{organization: organization, team: team}} ->
            {:ok,
             %{
               organization: organization,
               team: team,
               client_mutation_id: input.client_mutation_id
             }}

          {:error, reason} ->
            {:ok, Errors.business_error(reason, input.client_mutation_id)}
        end
    end
  end

  def create_team(_parent, %{input: input}, %{context: %{scope: scope}}) do
    if Scope.has_organization_role?(scope, [:organization_owner, :organization_admin]) do
      attrs =
        input
        |> Map.take([:name, :legal_name, :base_currency, :time_zone, :locale])
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      case Orgs.create_team(scope.organization, attrs, scope) do
        {:ok, team} ->
          {:ok, %{team: team, client_mutation_id: input.client_mutation_id}}

        {:error, reason} ->
          {:ok, Errors.business_error(reason, input.client_mutation_id)}
      end
    else
      {:ok, Errors.authorization(input.client_mutation_id)}
    end
  end

  defp stringify_roles(%{roles: roles} = row) do
    %{row | roles: Enum.map(roles, &to_string/1)}
  end
end
