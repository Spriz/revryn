defmodule BillingCoreWeb.GraphQL.LimitsTest do
  @moduledoc """
  Transport and execution budgets (SPEC §14.7): malformed documents,
  weighted complexity, and the document byte-size guard produce stable,
  client-handleable rejections.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  setup %{conn: conn} do
    Map.put(register_actor(), :conn, conn)
  end

  test "a malformed document is rejected without execution", ctx do
    {status, body} = gql(ctx.conn, "query { customer(", token: ctx.token)

    assert status in [200, 400]
    assert [%{"message" => message} | _] = body["errors"]
    assert message =~ ~r/syntax|parse/i
    refute Map.has_key?(body, "data") and body["data"] != nil
  end

  test "an over-complex query is rejected by weighted complexity accounting", ctx do
    # Several maximum-cardinality connections in one document blow the
    # router's complexity budget (max_complexity: 250).
    query = """
    query TooComplex($teamId: ID!) {
      a: customers(teamId: $teamId, first: 100) {
        edges { cursor node { id externalId legalName currentVersion status } }
        pageInfo { hasNextPage endCursor }
      }
      b: customers(teamId: $teamId, first: 100) {
        edges { cursor node { id externalId legalName currentVersion status } }
        pageInfo { hasNextPage endCursor }
      }
      c: customers(teamId: $teamId, first: 100) {
        edges { cursor node { id externalId legalName currentVersion status } }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    {200, body} =
      gql(ctx.conn, query, token: ctx.token, variables: %{"teamId" => ctx.team.id})

    assert [%{"message" => message} | _] = body["errors"]
    assert message =~ ~r/complexity/i
  end

  test "documents over the byte budget get HTTP 413 with a stable code", ctx do
    padding = String.duplicate("x", 70_000)
    query = "query { apiVersion } # #{padding}"

    {413, body} = gql(ctx.conn, query, token: ctx.token)

    assert [%{"extensions" => %{"code" => "DOCUMENT_TOO_LARGE"}}] = body["errors"]
  end

  test "unknown fields fail validation with no partial execution", ctx do
    {200, body} = gql(ctx.conn, "query { secretInternals }", token: ctx.token)

    assert [%{"message" => message} | _] = body["errors"]
    assert message =~ "Cannot query field"
  end
end
