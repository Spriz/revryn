defmodule BillingCoreWeb.GraphQL.PaginationTest do
  @moduledoc """
  Bounded keyset cursor connections (SPEC §14.6): deterministic ordering
  with an ID tie-break, opaque cursors, and enforced page sizes.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  @customers """
  query Customers($teamId: ID!, $first: Int, $after: String) {
    customers(teamId: $teamId, first: $first, after: $after) {
      edges { cursor node { id externalId } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  setup %{conn: conn} do
    ctx = register_actor()

    customers =
      for suffix <- ["a", "b", "c"] do
        customer_fixture(ctx.scope, %{external_id: "page-#{suffix}"})
      end

    ctx |> Map.put(:conn, conn) |> Map.put(:customers, customers)
  end

  test "first: 2 pages deterministically and the end cursor continues", ctx do
    {200, %{"data" => %{"customers" => page}}} =
      gql(ctx.conn, @customers,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "first" => 2}
      )

    assert [%{"node" => %{"externalId" => "page-a"}}, %{"node" => %{"externalId" => "page-b"}}] =
             page["edges"]

    assert page["pageInfo"]["hasNextPage"] == true
    end_cursor = page["pageInfo"]["endCursor"]
    assert is_binary(end_cursor)
    assert end_cursor == List.last(page["edges"])["cursor"]

    {200, %{"data" => %{"customers" => rest}}} =
      gql(ctx.conn, @customers,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "first" => 2, "after" => end_cursor}
      )

    assert [%{"node" => %{"externalId" => "page-c"}}] = rest["edges"]
    assert rest["pageInfo"]["hasNextPage"] == false
  end

  test "page sizes are bounded server-side", ctx do
    for bad_first <- [0, 101] do
      {200, body} =
        gql(ctx.conn, @customers,
          token: ctx.token,
          variables: %{"teamId" => ctx.team.id, "first" => bad_first}
        )

      assert [%{"code" => "INVALID_PAGE_SIZE"} | _] = body["errors"]
    end
  end

  test "a garbled cursor is rejected with a stable code", ctx do
    {200, body} =
      gql(ctx.conn, @customers,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "first" => 2, "after" => "not-a-cursor"}
      )

    assert [%{"code" => "INVALID_CURSOR"} | _] = body["errors"]
  end
end
