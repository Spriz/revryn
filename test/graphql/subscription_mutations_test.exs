defmodule BillingCoreWeb.GraphQL.SubscriptionMutationsTest do
  @moduledoc """
  createSubscription per SPEC §14.9 with §14.3 idempotency semantics, plus
  quantity change and cancellation commands.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  @create_subscription """
  mutation CreateSubscription($input: CreateSubscriptionInput!) {
    createSubscription(input: $input) {
      __typename
      ... on CreateSubscriptionSuccess {
        clientMutationId
        subscription { id version state startsOn externalId }
      }
      ... on ValidationProblem { code message fields { path code message } }
      ... on IdempotencyConflict { code message clientMutationId }
      ... on AuthorizationProblem { code message }
    }
  }
  """

  defp subscription_input(team, contract, plan_version, overrides \\ %{}) do
    Map.merge(
      %{
        "teamId" => team.id,
        "contractId" => contract.id,
        "externalId" => "sub-gql-#{System.unique_integer([:positive])}",
        "planVersionId" => plan_version.id,
        "startsOn" => Date.to_iso8601(Date.utc_today()),
        "quantity" => "2",
        "idempotencyKey" => "key-#{System.unique_integer([:positive])}",
        "clientMutationId" => "cm-1"
      },
      overrides
    )
  end

  setup %{conn: conn} do
    actor = %{team: team, scope: scope} = register_actor()
    plan_version = published_plan_version_fixture(scope)
    contract = contract_fixture(scope)
    Map.merge(actor, %{conn: conn, plan_version: plan_version, contract: contract, team: team})
  end

  test "happy path returns the typed success payload (SPEC §14.9)", ctx do
    input = subscription_input(ctx.team, ctx.contract, ctx.plan_version)

    {200, %{"data" => %{"createSubscription" => payload}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => input})

    assert payload["__typename"] == "CreateSubscriptionSuccess"
    assert payload["clientMutationId"] == "cm-1"

    subscription = payload["subscription"]
    assert subscription["state"] == "active"
    assert subscription["version"] == 1
    assert subscription["startsOn"] == input["startsOn"]
    assert subscription["externalId"] == input["externalId"]
  end

  test "replaying the same canonical command returns the same subscription", ctx do
    input = subscription_input(ctx.team, ctx.contract, ctx.plan_version)

    {200, %{"data" => %{"createSubscription" => first}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => input})

    assert first["__typename"] == "CreateSubscriptionSuccess"

    # Same idempotency key + same canonical input (clientMutationId may vary).
    replay_input = Map.put(input, "clientMutationId", "cm-2")

    {200, %{"data" => %{"createSubscription" => replay}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => replay_input})

    assert replay["__typename"] == "CreateSubscriptionSuccess"
    assert replay["subscription"]["id"] == first["subscription"]["id"]
    assert replay["clientMutationId"] == "cm-2"
  end

  test "reusing the key with materially different input is an IdempotencyConflict", ctx do
    input = subscription_input(ctx.team, ctx.contract, ctx.plan_version)

    {200, %{"data" => %{"createSubscription" => first}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => input})

    assert first["__typename"] == "CreateSubscriptionSuccess"

    different = Map.put(input, "quantity", "9")

    {200, %{"data" => %{"createSubscription" => conflict}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => different})

    assert conflict["__typename"] == "IdempotencyConflict"
    assert conflict["code"] == "IDEMPOTENCY_KEY_REUSED"
  end

  test "business validation is a typed problem, not a bare error", ctx do
    # Start date outside the contract period (contract starts 2026-01-01).
    input =
      subscription_input(ctx.team, ctx.contract, ctx.plan_version, %{
        "startsOn" => "2020-01-01"
      })

    {200, %{"data" => %{"createSubscription" => payload}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => input})

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "OUTSIDE_CONTRACT_PERIOD"
  end

  test "a mutation without team membership resolves to AuthorizationProblem", ctx do
    %{token: outsider_token} = register_actor()
    input = subscription_input(ctx.team, ctx.contract, ctx.plan_version)

    {200, %{"data" => %{"createSubscription" => payload}}} =
      gql(ctx.conn, @create_subscription, token: outsider_token, variables: %{"input" => input})

    assert payload["__typename"] == "AuthorizationProblem"
    assert payload["code"] == "UNAUTHORIZED"
  end

  test "changing or cancelling an unknown subscription is a typed NOT_FOUND", ctx do
    change = """
    mutation ChangeSubscription($input: ChangeSubscriptionInput!) {
      changeSubscription(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"changeSubscription" => changed}}} =
      gql(ctx.conn, change,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => Ecto.UUID.generate(),
            "quantity" => "5",
            "idempotencyKey" => "change-missing",
            "clientMutationId" => "cm-change-missing"
          }
        }
      )

    assert changed["__typename"] == "ValidationProblem"
    assert changed["code"] == "NOT_FOUND"

    cancel = """
    mutation CancelSubscription($input: CancelSubscriptionInput!) {
      cancelSubscription(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"cancelSubscription" => cancelled}}} =
      gql(ctx.conn, cancel,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => Ecto.UUID.generate(),
            "mode" => "IMMEDIATE",
            "idempotencyKey" => "cancel-missing",
            "clientMutationId" => "cm-cancel-missing"
          }
        }
      )

    assert cancelled["__typename"] == "ValidationProblem"
    assert cancelled["code"] == "NOT_FOUND"
  end

  test "changeSubscription appends a version; cancelSubscription follows §11.1", ctx do
    input = subscription_input(ctx.team, ctx.contract, ctx.plan_version)

    {200, %{"data" => %{"createSubscription" => created}}} =
      gql(ctx.conn, @create_subscription, token: ctx.token, variables: %{"input" => input})

    subscription_id = created["subscription"]["id"]

    change = """
    mutation ChangeSubscription($input: ChangeSubscriptionInput!) {
      changeSubscription(input: $input) {
        __typename
        ... on ChangeSubscriptionSuccess { subscription { id currentVersion } }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"changeSubscription" => changed}}} =
      gql(ctx.conn, change,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => subscription_id,
            "quantity" => "5",
            "idempotencyKey" => "change-1",
            "clientMutationId" => "cm-change"
          }
        }
      )

    assert changed["__typename"] == "ChangeSubscriptionSuccess"
    assert changed["subscription"]["currentVersion"] == 2

    cancel = """
    mutation CancelSubscription($input: CancelSubscriptionInput!) {
      cancelSubscription(input: $input) {
        __typename
        ... on CancelSubscriptionSuccess { subscription { id state endDateExclusive } }
        ... on ValidationProblem { code }
      }
    }
    """

    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    {200, %{"data" => %{"cancelSubscription" => cancelled}}} =
      gql(ctx.conn, cancel,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => subscription_id,
            "mode" => "IMMEDIATE",
            "effectiveDate" => tomorrow,
            "reason" => "customer request",
            "idempotencyKey" => "cancel-1",
            "clientMutationId" => "cm-cancel"
          }
        }
      )

    assert cancelled["__typename"] == "CancelSubscriptionSuccess"
    assert cancelled["subscription"]["state"] == "cancelled"
    assert cancelled["subscription"]["endDateExclusive"] == tomorrow
  end
end
