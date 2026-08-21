defmodule BillingCoreWeb.GraphQL.Middleware.RequireScope do
  @moduledoc """
  Resolves the caller's organization/team scope before resolution
  (SPEC §14.2, INV-024/025).

  Every team/organization-scoped field carries explicit `teamId` /
  `organizationId` arguments; this middleware resolves them against the
  authenticated principal via `BillingCore.Orgs.resolve_scope/3` and puts
  the resulting `BillingCore.Scope` into the resolution context. Possession
  of an ID never grants access — a missing membership, unknown ID, and a
  cross-organization ID all fail identically as unauthorized.

  Options:

    * `mode: :query | :mutation` — failure shape: queries get a stable-coded
      GraphQL error, mutations resolve to a typed `AuthorizationProblem`
      union member (SPEC §14.4).
  """

  @behaviour Absinthe.Middleware

  import Ecto.Query

  alias Absinthe.Resolution
  alias BillingCore.{Orgs, Repo}
  alias BillingCoreWeb.GraphQL.Errors

  @impl Absinthe.Middleware
  def call(%Resolution{state: :resolved} = resolution, _opts), do: resolution

  def call(%Resolution{} = resolution, opts) do
    mode = Keyword.get(opts, :mode, :query)
    args = scoped_args(resolution.arguments)

    case resolution.context[:current_user] do
      nil ->
        fail(resolution, mode, args, :unauthenticated)

      user ->
        case resolve_scope(user, args) do
          {:ok, scope} ->
            scope = %{scope | correlation_id: resolution.context[:correlation_id]}
            %{resolution | context: Map.put(resolution.context, :scope, scope)}

          {:error, :unauthorized} ->
            fail(resolution, mode, args, :unauthorized)
        end
    end
  end

  defp scoped_args(%{input: %{} = input}), do: input
  defp scoped_args(args), do: args

  defp resolve_scope(user, args) do
    team_id = args[:team_id]
    organization_id = args[:organization_id] || organization_id_for_team(team_id)

    if is_nil(organization_id) do
      {:error, :unauthorized}
    else
      Orgs.resolve_scope(user, organization_id, team_id)
    end
  end

  # Authorization plumbing: a teamId-only operation must resolve the team's
  # organization before scope resolution (SPEC §14.2).
  defp organization_id_for_team(nil), do: nil

  defp organization_id_for_team(team_id) do
    case Ecto.UUID.cast(team_id) do
      {:ok, uuid} ->
        Repo.one(
          from t in "teams",
            prefix: "billing",
            where: t.id == type(^uuid, Ecto.UUID),
            select: type(t.organization_id, Ecto.UUID)
        )

      :error ->
        nil
    end
  end

  defp fail(resolution, :query, _args, :unauthenticated) do
    Resolution.put_result(resolution, Errors.unauthenticated())
  end

  defp fail(resolution, :query, _args, :unauthorized) do
    Resolution.put_result(resolution, Errors.unauthorized())
  end

  defp fail(resolution, :mutation, args, _reason) do
    Resolution.put_result(
      resolution,
      {:ok, Errors.authorization(args[:client_mutation_id])}
    )
  end
end
