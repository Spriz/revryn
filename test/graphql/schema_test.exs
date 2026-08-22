defmodule BillingCoreWeb.GraphQL.SchemaTest do
  @moduledoc """
  Schema-level wiring (SPEC §14): the crash-shield middleware wraps every
  resolver, batch resolution is enabled, and the contract-version marker
  resolves over the real HTTP endpoint.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  alias BillingCoreWeb.GraphQL.{Middleware, Schema}

  describe "middleware/3" do
    test "wraps resolver middleware in SafeResolution and leaves the rest" do
      resolver = fn _, _, _ -> {:ok, 1} end

      middleware = [
        {Middleware.RequireScope, [mode: :query]},
        {{Absinthe.Resolution, :call}, resolver}
      ]

      assert Schema.middleware(middleware, :field, :object) == [
               {Middleware.RequireScope, [mode: :query]},
               {Middleware.SafeResolution, resolver}
             ]
    end

    test "an empty middleware chain stays empty" do
      assert Schema.middleware([], :field, :object) == []
    end
  end

  describe "plugins/0" do
    test "includes the Batch plugin alongside the defaults" do
      plugins = Schema.plugins()

      assert Absinthe.Middleware.Batch in plugins
      assert Enum.all?(Absinthe.Plugin.defaults(), &(&1 in plugins))
    end
  end

  describe "apiVersion" do
    test "resolves the contract version marker without authentication", %{conn: conn} do
      {200, %{"data" => %{"apiVersion" => "1"}}} = gql(conn, "query { apiVersion }")
    end
  end

  describe "connection complexity weighting (SPEC §14.7)" do
    setup %{conn: conn} do
      Map.put(register_actor(), :conn, conn)
    end

    test "small pages over every weighted connection stay within budget", ctx do
      query = """
      query Small($teamId: ID!) {
        customers(teamId: $teamId, first: 1) { edges { node { id } } }
        subscriptions(teamId: $teamId, first: 1) { edges { node { id } } }
        products(teamId: $teamId, first: 1) { edges { node { id } } }
      }
      """

      {200, body} =
        gql(ctx.conn, query, token: ctx.token, variables: %{"teamId" => ctx.team.id})

      refute body["errors"]
      assert body["data"]["customers"]["edges"] == []
      assert body["data"]["subscriptions"]["edges"] == []
      assert body["data"]["products"]["edges"] == []
    end

    test "maximum-cardinality pages across connections blow the budget", ctx do
      query = """
      query TooComplex($teamId: ID!) {
        subscriptions(teamId: $teamId, first: 100) {
          edges { cursor node { id externalId state startsOn timeZone currentVersion } }
          pageInfo { hasNextPage endCursor }
        }
        products(teamId: $teamId, first: 100) {
          edges { cursor node { id code name status recognitionMode currentVersion } }
          pageInfo { hasNextPage endCursor }
        }
      }
      """

      {200, body} =
        gql(ctx.conn, query, token: ctx.token, variables: %{"teamId" => ctx.team.id})

      assert body["data"] == nil
      assert [%{"message" => message} | _] = body["errors"]
      assert message =~ ~r/complexity/i
    end
  end
end
