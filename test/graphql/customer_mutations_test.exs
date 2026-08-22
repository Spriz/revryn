defmodule BillingCoreWeb.GraphQL.CustomerMutationsTest do
  @moduledoc """
  upsertCustomer: immutable version snapshots, optimistic concurrency via
  expectedVersion (SPEC §14.3), and idempotent replay.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  alias BillingCore.Contracts

  @upsert """
  mutation UpsertCustomer($input: UpsertCustomerInput!) {
    upsertCustomer(input: $input) {
      __typename
      ... on UpsertCustomerSuccess {
        clientMutationId
        customer { id externalId currentVersion legalName }
      }
      ... on ValidationProblem { code message fields { path code message } }
      ... on VersionConflict { expectedVersion actualVersion clientMutationId }
      ... on IdempotencyConflict { code }
      ... on AuthorizationProblem { code }
    }
  }
  """

  defp customer_input(team, overrides \\ %{}) do
    Map.merge(
      %{
        "teamId" => team.id,
        "externalId" => "cust-gql-#{System.unique_integer([:positive])}",
        "legalName" => "Acme ApS",
        "country" => "DK",
        "email" => "billing@example.com",
        "city" => "Aarhus",
        "idempotencyKey" => "cust-key-#{System.unique_integer([:positive])}",
        "clientMutationId" => "cm-upsert"
      },
      overrides
    )
  end

  setup %{conn: conn} do
    Map.put(register_actor(), :conn, conn)
  end

  test "creates version 1 and bumps to version 2 on a changed snapshot", ctx do
    input = customer_input(ctx.team)

    {200, %{"data" => %{"upsertCustomer" => created}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => input})

    assert created["__typename"] == "UpsertCustomerSuccess"
    assert created["customer"]["currentVersion"] == 1
    assert created["customer"]["legalName"] == "Acme ApS"

    changed =
      input
      |> Map.put("legalName", "Acme Holding ApS")
      |> Map.put("idempotencyKey", "cust-key-#{System.unique_integer([:positive])}")

    {200, %{"data" => %{"upsertCustomer" => updated}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => changed})

    assert updated["customer"]["id"] == created["customer"]["id"]
    assert updated["customer"]["currentVersion"] == 2
    assert updated["customer"]["legalName"] == "Acme Holding ApS"
  end

  test "a stale expectedVersion is a VersionConflict and writes nothing", ctx do
    input = customer_input(ctx.team)

    {200, %{"data" => %{"upsertCustomer" => created}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => input})

    customer_id = created["customer"]["id"]
    assert created["customer"]["currentVersion"] == 1

    stale =
      input
      |> Map.put("legalName", "Should Not Persist ApS")
      |> Map.put("expectedVersion", 7)
      |> Map.put("idempotencyKey", "cust-key-#{System.unique_integer([:positive])}")

    {200, %{"data" => %{"upsertCustomer" => conflict}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => stale})

    assert conflict["__typename"] == "VersionConflict"
    assert conflict["expectedVersion"] == 7
    assert conflict["actualVersion"] == 1
    assert conflict["clientMutationId"] == "cm-upsert"

    # No write happened: the customer still has one version.
    {:ok, customer} = Contracts.get_customer(ctx.scope, customer_id)
    assert customer.current_version == 1
    {:ok, versions} = Contracts.list_customer_versions(ctx.scope, customer)
    assert [%{version: 1, legal_name: "Acme ApS"}] = versions

    # A matching expectedVersion succeeds.
    current =
      stale
      |> Map.put("expectedVersion", 1)
      |> Map.put("idempotencyKey", "cust-key-#{System.unique_integer([:positive])}")

    {200, %{"data" => %{"upsertCustomer" => ok}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => current})

    assert ok["__typename"] == "UpsertCustomerSuccess"
    assert ok["customer"]["currentVersion"] == 2
  end

  test "replay with the same key returns the same customer without a new version", ctx do
    input = customer_input(ctx.team)

    {200, %{"data" => %{"upsertCustomer" => first}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => input})

    {200, %{"data" => %{"upsertCustomer" => replay}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => input})

    assert replay["__typename"] == "UpsertCustomerSuccess"
    assert replay["customer"]["id"] == first["customer"]["id"]
    assert replay["customer"]["currentVersion"] == 1
  end

  test "an explicit null expectedVersion skips the optimistic check", ctx do
    input = Map.put(customer_input(ctx.team), "expectedVersion", nil)

    {200, %{"data" => %{"upsertCustomer" => created}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => input})

    assert created["__typename"] == "UpsertCustomerSuccess"
    assert created["customer"]["currentVersion"] == 1
  end

  test "invalid input surfaces field-level problems", ctx do
    input = customer_input(ctx.team, %{"email" => "not-an-email"})

    {200, %{"data" => %{"upsertCustomer" => problem}}} =
      gql(ctx.conn, @upsert, token: ctx.token, variables: %{"input" => input})

    assert problem["__typename"] == "ValidationProblem"
    assert problem["code"] == "VALIDATION_FAILED"
    assert Enum.any?(problem["fields"], &(&1["path"] == ["email"]))
  end
end
