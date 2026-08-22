defmodule BillingCoreWeb.GraphQL.UsageBatchLimitTest do
  @moduledoc """
  Batch ingestion cap (BC-US-051): a batch above the configured maximum is
  rejected atomically with a typed ValidationProblem — no partial writes.

  async: false — the cap is application configuration; the transport-level
  64 KiB document guard makes the default cap of 1000 unreachable over
  HTTP, so the test lowers it.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  alias BillingCore.{Contracts, Usage}

  setup %{conn: conn} do
    previous = Application.get_env(:billing_core, Usage, [])
    Application.put_env(:billing_core, Usage, Keyword.put(previous, :max_batch_size, 2))
    on_exit(fn -> Application.put_env(:billing_core, Usage, previous) end)

    actor = register_actor([:team_admin, :billing_admin, :integration_client])

    plan_version = published_plan_version_fixture(actor.scope)
    contract = contract_fixture(actor.scope, %{start_date: ~D[2026-01-01]})

    {:ok, subscription} =
      Contracts.start_subscription(actor.scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: ~D[2026-08-01],
        quantity: Decimal.new(1)
      })

    Map.merge(actor, %{conn: conn, subscription: subscription})
  end

  test "a batch above the cap is BATCH_TOO_LARGE and writes nothing", ctx do
    batch = """
    mutation Batch($input: IngestUsageBatchInput!) {
      ingestUsageBatch(input: $input) {
        __typename
        ... on ValidationProblem { code clientMutationId }
      }
    }
    """

    events =
      for n <- 1..3 do
        %{
          "externalEventId" => "cap-#{n}",
          "subscriptionId" => ctx.subscription.id,
          "metricCode" => "api_calls",
          "occurredAt" => "2026-08-05T10:00:00Z",
          "value" => "1"
        }
      end

    {200, %{"data" => %{"ingestUsageBatch" => payload}}} =
      gql(ctx.conn, batch,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.subscription.team_id,
            "events" => events,
            "clientMutationId" => "cap"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "BATCH_TOO_LARGE"
    assert payload["clientMutationId"] == "cap"

    # Atomic rejection: none of the three events landed.
    {:ok, aggregate} =
      Usage.aggregate(
        ctx.scope,
        ctx.subscription,
        "api_calls",
        BillingCore.Domain.Period.new!(~D[2026-08-01], ~D[2026-09-01]),
        DateTime.utc_now()
      )

    assert aggregate.event_count == 0
  end
end
