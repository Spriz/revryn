defmodule BillingCoreWeb.GraphQL.UsageTest do
  @moduledoc """
  GraphQL usage ingestion and aggregation (SPEC §14.5/§14.10,
  BC-US-050…053).
  """

  use BillingCoreWeb.GraphQLCase, async: true

  alias BillingCore.Contracts

  setup %{conn: conn} do
    actor = register_actor([:team_admin, :billing_admin, :integration_client])
    scope = actor.scope

    plan_version =
      published_plan_version_fixture(scope,
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        amount: "100.00"
      )

    contract = contract_fixture(scope, %{start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    Map.merge(actor, %{subscription: subscription, conn: conn})
  end

  defp mutate!(ctx, document, variables) do
    {200, %{"data" => data} = body} =
      gql(ctx.conn, document, variables: variables, token: ctx.token)

    refute body["errors"], "unexpected errors: #{inspect(body["errors"])}"
    data
  end

  defp query!(ctx, document, variables), do: mutate!(ctx, document, variables)

  @ingest """
  mutation Ingest($input: IngestUsageEventInput!) {
    ingestUsageEvent(input: $input) {
      ... on IngestUsageEventSuccess {
        outcome { status usageEventId quarantineReason }
        duplicate
        clientMutationId
      }
      ... on UsageEventConflict { code message }
    }
  }
  """

  defp ingest_input(subscription, overrides \\ %{}) do
    Map.merge(
      %{
        "teamId" => subscription.team_id,
        "externalEventId" => "gql-#{System.unique_integer([:positive])}",
        "subscriptionId" => subscription.id,
        "metricCode" => "api_calls",
        "occurredAt" => "2026-08-10T10:00:00Z",
        "value" => "5",
        "clientMutationId" => "m1"
      },
      overrides
    )
  end

  test "ingest → duplicate replay → conflicting payload (§14.10)", ctx do
    input = ingest_input(ctx.subscription)

    data = mutate!(ctx, @ingest, %{"input" => input})

    assert %{"outcome" => %{"status" => "accepted"}, "duplicate" => false} =
             data["ingestUsageEvent"]

    replay = mutate!(ctx, @ingest, %{"input" => input})

    assert %{"outcome" => %{"status" => "duplicate"}, "duplicate" => true} =
             replay["ingestUsageEvent"]

    conflicting = mutate!(ctx, @ingest, %{"input" => Map.put(input, "value", "999")})
    assert %{"code" => "USAGE_EVENT_CONFLICT"} = conflicting["ingestUsageEvent"]
  end

  test "batch reports independent outcomes and usagePreview aggregates at a cutoff", ctx do
    batch = """
    mutation Batch($input: IngestUsageBatchInput!) {
      ingestUsageBatch(input: $input) {
        ... on IngestUsageBatchSuccess {
          accepted duplicate rejected quarantined
          items { externalEventId status detail }
        }
      }
    }
    """

    events = [
      %{
        "externalEventId" => "b-1-#{System.unique_integer([:positive])}",
        "subscriptionId" => ctx.subscription.id,
        "metricCode" => "api_calls",
        "occurredAt" => "2026-08-05T10:00:00Z",
        "value" => "3"
      },
      %{
        "externalEventId" => "b-2-#{System.unique_integer([:positive])}",
        "subscriptionExternalId" => "unknown-subscription",
        "metricCode" => "api_calls",
        "occurredAt" => "2026-08-05T10:00:00Z",
        "value" => "4"
      }
    ]

    data =
      mutate!(ctx, batch, %{
        "input" => %{
          "teamId" => ctx.subscription.team_id,
          "events" => events,
          "clientMutationId" => "b"
        }
      })

    assert %{"accepted" => 1, "quarantined" => 1, "items" => [item]} = data["ingestUsageBatch"]
    assert item["status"] == "quarantined"

    preview = """
    query Preview($teamId: ID!, $subscriptionId: ID!) {
      usagePreview(
        teamId: $teamId
        subscriptionId: $subscriptionId
        metricCode: "api_calls"
        periodStart: "2026-08-01"
        periodEndExclusive: "2026-09-01"
      ) {
        quantity eventCount aggregation excludedLate
      }
    }
    """

    result =
      query!(ctx, preview, %{
        "teamId" => ctx.subscription.team_id,
        "subscriptionId" => ctx.subscription.id
      })

    assert %{"quantity" => "3", "eventCount" => 1, "aggregation" => "sum"} =
             result["usagePreview"]
  end

  test "voidUsageEvent voids idempotently", ctx do
    input = ingest_input(ctx.subscription)
    mutate!(ctx, @ingest, %{"input" => input})

    void = """
    mutation Void($input: VoidUsageEventInput!) {
      voidUsageEvent(input: $input) {
        ... on VoidUsageEventSuccess { status }
        ... on UsageEventConflict { code }
      }
    }
    """

    void_input = %{
      "teamId" => ctx.subscription.team_id,
      "externalEventId" => input["externalEventId"],
      "voidEventId" => "void-#{System.unique_integer([:positive])}",
      "clientMutationId" => "v"
    }

    assert %{"voidUsageEvent" => %{"status" => "voided"}} =
             mutate!(ctx, void, %{"input" => void_input})

    assert %{"voidUsageEvent" => %{"status" => "already_voided"}} =
             mutate!(ctx, void, %{"input" => void_input})
  end
end
