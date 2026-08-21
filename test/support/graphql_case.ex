defmodule BillingCoreWeb.GraphQLCase do
  @moduledoc """
  Test case for the public GraphQL API: real HTTP posts through the endpoint
  with Bearer session-token authentication (SPEC §14.1/§14.2).
  """

  use ExUnit.CaseTemplate

  alias BillingCore.{Identity, Orgs}

  using do
    quote do
      @endpoint BillingCoreWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import BillingCoreWeb.GraphQLCase

      import BillingCore.IdentityFixtures
      import BillingCore.OrgsFixtures
      import BillingCore.ContractsFixtures
      import BillingCore.CatalogFixtures
    end
  end

  setup tags do
    BillingCore.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates a user with an organization, a team, the given team roles, and an
  authenticated session. Returns `%{user, organization, team, token, scope}`.
  """
  def register_actor(team_roles \\ [:team_admin, :billing_admin, :finance_operator]) do
    user = BillingCore.IdentityFixtures.user_fixture()

    %{organization: organization, team: team, team_membership: membership} =
      BillingCore.OrgsFixtures.organization_fixture(%{owner: user})

    {:ok, _membership} = Orgs.change_team_roles(membership, team_roles)
    {:ok, scope} = Orgs.resolve_scope(user, organization.id, team.id)
    {token, _session} = Identity.create_session(user)

    %{user: user, organization: organization, team: team, token: token, scope: scope}
  end

  @doc """
  Posts a GraphQL document to `/graphql`. Options: `:token` (Bearer),
  `:variables`. Returns `{status, decoded_body}`.
  """
  def gql(conn, query, opts \\ []) do
    body = Jason.encode!(%{query: query, variables: opts[:variables] || %{}})

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> put_token(opts[:token])
    |> Phoenix.ConnTest.dispatch(BillingCoreWeb.Endpoint, :post, "/graphql", body)
    |> then(fn conn -> {conn.status, Jason.decode!(conn.resp_body)} end)
  end

  defp put_token(conn, nil), do: conn

  defp put_token(conn, token) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end
end
