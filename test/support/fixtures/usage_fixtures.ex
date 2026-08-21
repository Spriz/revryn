defmodule BillingCore.UsageFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Usage` context.
  """

  import BillingCore.ContractsFixtures

  alias BillingCore.Usage

  @doc "A unique usage event external ID."
  def unique_usage_event_id, do: "evt-#{System.unique_integer([:positive])}"

  @doc """
  A team-resolved scope whose user may ingest usage (default
  `[:billing_admin]`; pass e.g. `[:integration_client]`).
  """
  def usage_scope_fixture(roles \\ [:billing_admin]), do: billing_scope_fixture(roles)

  @doc """
  An active subscription for usage tests, on a contract starting well in the
  past so recent `occurred_at` instants fall inside it.
  """
  def usage_subscription_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:contract_id, fn ->
        contract_fixture(scope, %{start_date: ~D[2026-01-01]}).id
      end)

    subscription_fixture(scope, attrs)
  end

  @doc "Complete usage event attrs for `subscription`; override any key."
  def valid_usage_event_attrs(subscription, attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put_new(:external_event_id, unique_usage_event_id())
    |> Map.put_new(:subscription_id, subscription.id)
    |> Map.put_new(:metric_code, "api_calls")
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> Map.put_new(:value, Decimal.new(1))
    |> Map.put_new(:properties, %{})
  end

  @doc "Ingests an accepted usage event and returns the ingest result map."
  def ingested_usage_event_fixture(scope, subscription, attrs \\ %{}) do
    {:ok, %{status: :accepted} = result} =
      Usage.ingest_event(scope, valid_usage_event_attrs(subscription, attrs))

    result
  end
end
