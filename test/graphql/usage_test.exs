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

  defp auditor_token(ctx) do
    auditor = user_fixture()
    organization_membership_fixture(ctx.organization, auditor)
    team_membership_fixture(ctx.team, auditor, [:auditor])
    {token, _session} = BillingCore.Identity.create_session(auditor)
    token
  end

  test "an event referencing an unknown subscription is quarantined, not lost", ctx do
    input =
      ctx.subscription
      |> ingest_input(%{"subscriptionExternalId" => "never-registered"})
      |> Map.delete("subscriptionId")

    data = mutate!(ctx, @ingest, %{"input" => input})

    assert %{"outcome" => outcome, "duplicate" => false} = data["ingestUsageEvent"]
    assert outcome["status"] == "quarantined"
    assert is_binary(outcome["quarantineReason"])
  end

  test "an event without any subscription reference is a typed ValidationProblem", ctx do
    ingest = """
    mutation Ingest($input: IngestUsageEventInput!) {
      ingestUsageEvent(input: $input) {
        __typename
        ... on ValidationProblem { code message clientMutationId }
      }
    }
    """

    input =
      ctx.subscription
      |> ingest_input()
      |> Map.delete("subscriptionId")

    data = mutate!(ctx, ingest, %{"input" => input})

    assert %{"__typename" => "ValidationProblem", "code" => "INVALID_EVENT"} =
             data["ingestUsageEvent"]

    assert data["ingestUsageEvent"]["clientMutationId"] == "m1"
  end

  test "an auditor cannot ingest, batch-ingest, or void (role enforcement)", ctx do
    token = auditor_token(ctx)
    auditor_ctx = %{ctx | token: token}

    ingest = """
    mutation Ingest($input: IngestUsageEventInput!) {
      ingestUsageEvent(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
      }
    }
    """

    data = mutate!(auditor_ctx, ingest, %{"input" => ingest_input(ctx.subscription)})

    assert %{"__typename" => "AuthorizationProblem", "code" => "UNAUTHORIZED"} =
             data["ingestUsageEvent"]

    batch = """
    mutation Batch($input: IngestUsageBatchInput!) {
      ingestUsageBatch(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
      }
    }
    """

    batch_data =
      mutate!(auditor_ctx, batch, %{
        "input" => %{
          "teamId" => ctx.subscription.team_id,
          "events" => [Map.drop(ingest_input(ctx.subscription), ["teamId", "clientMutationId"])],
          "clientMutationId" => "b-auditor"
        }
      })

    assert %{"__typename" => "AuthorizationProblem"} = batch_data["ingestUsageBatch"]

    void = """
    mutation Void($input: VoidUsageEventInput!) {
      voidUsageEvent(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
      }
    }
    """

    void_data =
      mutate!(auditor_ctx, void, %{
        "input" => %{
          "teamId" => ctx.subscription.team_id,
          "externalEventId" => "whatever",
          "voidEventId" => "void-auditor",
          "clientMutationId" => "v-auditor"
        }
      })

    assert %{"__typename" => "AuthorizationProblem"} = void_data["voidUsageEvent"]
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

    # A DIFFERENT void against the same measurement is a typed conflict
    # (at most one effective void per measurement, BC-US-052).
    conflicting = Map.put(void_input, "voidEventId", "void-#{System.unique_integer([:positive])}")

    assert %{"voidUsageEvent" => %{"code" => "ALREADY_VOIDED"}} =
             mutate!(ctx, void, %{"input" => conflicting})
  end

  @void_with_problems """
  mutation Void($input: VoidUsageEventInput!) {
    voidUsageEvent(input: $input) {
      __typename
      ... on VoidUsageEventSuccess { status }
      ... on ValidationProblem { code }
    }
  }
  """

  test "voiding an unknown measurement is a typed ValidationProblem", ctx do
    data =
      mutate!(ctx, @void_with_problems, %{
        "input" => %{
          "teamId" => ctx.subscription.team_id,
          "externalEventId" => "never-ingested",
          "voidEventId" => "void-#{System.unique_integer([:positive])}",
          "clientMutationId" => "v-missing"
        }
      })

    assert %{"__typename" => "ValidationProblem", "code" => "NOT_FOUND"} =
             data["voidUsageEvent"]
  end

  test "voidUsageEvent with a replacement swaps the measurement (BC-US-052)", ctx do
    input = ingest_input(ctx.subscription, %{"value" => "10"})
    mutate!(ctx, @ingest, %{"input" => input})

    data =
      mutate!(ctx, @void_with_problems, %{
        "input" => %{
          "teamId" => ctx.subscription.team_id,
          "externalEventId" => input["externalEventId"],
          "voidEventId" => "void-#{System.unique_integer([:positive])}",
          "replacement" => %{
            "externalEventId" => "repl-#{System.unique_integer([:positive])}",
            "subscriptionId" => ctx.subscription.id,
            "metricCode" => "api_calls",
            "occurredAt" => input["occurredAt"],
            "value" => "3"
          },
          "clientMutationId" => "v-repl"
        }
      })

    assert %{"__typename" => "VoidUsageEventSuccess", "status" => "voided"} =
             data["voidUsageEvent"]

    # Aggregation sees only the corrected measurement.
    preview = """
    query Preview($teamId: ID!, $subscriptionId: ID!) {
      usagePreview(
        teamId: $teamId
        subscriptionId: $subscriptionId
        metricCode: "api_calls"
        periodStart: "2026-08-01"
        periodEndExclusive: "2026-09-01"
      ) {
        quantity eventCount
      }
    }
    """

    result =
      query!(ctx, preview, %{
        "teamId" => ctx.subscription.team_id,
        "subscriptionId" => ctx.subscription.id
      })

    assert %{"quantity" => "3", "eventCount" => 1} = result["usagePreview"]
  end

  describe "usagePreview edges" do
    @preview """
    query Preview(
      $teamId: ID!
      $subscriptionId: ID!
      $periodStart: Date!
      $periodEndExclusive: Date!
      $aggregation: String
    ) {
      usagePreview(
        teamId: $teamId
        subscriptionId: $subscriptionId
        metricCode: "api_calls"
        periodStart: $periodStart
        periodEndExclusive: $periodEndExclusive
        aggregation: $aggregation
      ) {
        quantity eventCount aggregation
      }
    }
    """

    defp preview_variables(ctx, overrides) do
      Map.merge(
        %{
          "teamId" => ctx.subscription.team_id,
          "subscriptionId" => ctx.subscription.id,
          "periodStart" => "2026-08-01",
          "periodEndExclusive" => "2026-09-01"
        },
        overrides
      )
    end

    test "count aggregation counts events; unknown names fall back to sum", ctx do
      mutate!(ctx, @ingest, %{"input" => ingest_input(ctx.subscription, %{"value" => "7"})})
      mutate!(ctx, @ingest, %{"input" => ingest_input(ctx.subscription, %{"value" => "5"})})

      counted =
        query!(ctx, @preview, preview_variables(ctx, %{"aggregation" => "count"}))

      assert %{"aggregation" => "count", "quantity" => "2", "eventCount" => 2} =
               counted["usagePreview"]

      # An unrecognized aggregation name never reaches the domain: the
      # resolver whitelists and defaults to sum.
      defaulted =
        query!(ctx, @preview, preview_variables(ctx, %{"aggregation" => "definitely-not-real"}))

      assert %{"aggregation" => "sum", "quantity" => "12"} = defaulted["usagePreview"]
    end

    test "an inverted period is a stable INVALID_PERIOD error", ctx do
      {200, body} =
        gql(ctx.conn, @preview,
          token: ctx.token,
          variables:
            preview_variables(ctx, %{
              "periodStart" => "2026-09-01",
              "periodEndExclusive" => "2026-08-01"
            })
        )

      assert body["data"]["usagePreview"] == nil
      assert [%{"code" => "INVALID_PERIOD"} | _] = body["errors"]
    end

    test "an unknown subscription is NOT_FOUND without leaking detail", ctx do
      {200, body} =
        gql(ctx.conn, @preview,
          token: ctx.token,
          variables: preview_variables(ctx, %{"subscriptionId" => Ecto.UUID.generate()})
        )

      assert body["data"]["usagePreview"] == nil
      assert [%{"code" => "NOT_FOUND"} | _] = body["errors"]
    end

    # The resolver's UNAUTHORIZED and INVALID_AGGREGATION branches are
    # defensive: every canonical team role may read usage aggregates, and
    # the aggregation whitelist above matches the domain's known set — so
    # neither error can be produced over the HTTP surface today.
  end
end
