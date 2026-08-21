defmodule BillingCore.Billing.ListingTest do
  @moduledoc """
  Read-only run/intent listing helpers for the LiveView surfaces, plus the
  transition_intent nesting regression (INV-015).
  """

  use BillingCore.DataCase, async: true

  import BillingCore.ContractsFixtures
  import Ecto.Query

  alias BillingCore.Billing
  alias BillingCore.Billing.InvoiceIntent

  setup do
    %{scope: billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])}
  end

  defp open_run!(scope, invoice_date) do
    {:ok, run} =
      Billing.open_run(scope, %{
        run_key: "#{invoice_date}:regular:test",
        invoice_date: invoice_date,
        usage_cutoff: DateTime.new!(invoice_date, ~T[00:00:00.000000], "Etc/UTC")
      })

    run
  end

  defp freeze_intent!(scope, attrs \\ %{}) do
    customer = customer_fixture(scope)

    {:ok, intent} =
      Billing.freeze_invoice_intent(
        scope,
        Map.merge(
          %{
            customer_id: customer.id,
            customer_version: customer.current_version,
            customer_external_id: customer.external_id,
            customer_legal_name: "Acme ApS",
            currency: "DKK",
            invoice_date: ~D[2026-09-01],
            usage_cutoff: ~U[2026-09-01 00:00:00Z],
            lines: [
              %{
                line_key: "line-#{System.unique_integer([:positive])}",
                product_id: Ecto.UUID.generate(),
                product_version: 1,
                description: "Line",
                quantity: Decimal.new(1),
                amount_minor: 100,
                recognition_mode: :point_in_time,
                calculation_trace: %{"model" => "test"},
                ordinal: 0
              }
            ]
          },
          Map.new(attrs)
        )
      )

    intent
  end

  test "list_runs/get_run/count_open_runs are team-scoped", %{scope: scope} do
    run = open_run!(scope, ~D[2026-09-01])
    _closed = open_run!(scope, ~D[2026-08-01])

    assert {:ok, runs} = Billing.list_runs(scope)
    assert length(runs) == 2
    assert hd(runs).invoice_date == ~D[2026-09-01]

    assert {:ok, fetched} = Billing.get_run(scope, run.id)
    assert fetched.id == run.id
    assert {:ok, 2} = Billing.count_open_runs(scope)

    other_scope = billing_scope_fixture([:finance_operator])
    assert {:error, :not_found} = Billing.get_run(other_scope, run.id)
    assert {:ok, []} = Billing.list_runs(other_scope)
  end

  test "list_run_intents/2 pairs intents with lifecycle state", %{scope: scope} do
    run = open_run!(scope, ~D[2026-09-01])
    assert {:ok, []} = Billing.list_run_intents(scope, run)

    intent = freeze_intent!(scope, %{billing_run_id: run.id})

    assert {:ok, [%{intent: listed, state: "frozen"}]} = Billing.list_run_intents(scope, run)
    assert listed.id == intent.id
  end

  test "list_intents/2 filters by customer and state", %{scope: scope} do
    intent = freeze_intent!(scope)

    assert {:ok, [%{intent: listed, state: "frozen"}]} = Billing.list_intents(scope)
    assert listed.id == intent.id

    assert {:ok, [_entry]} = Billing.list_intents(scope, customer_id: intent.customer_id)
    assert {:ok, []} = Billing.list_intents(scope, customer_id: Ecto.UUID.generate())
    assert {:ok, []} = Billing.list_intents(scope, state: "erp_booked")
  end

  test "list_intent_transitions/2 returns the append-only history", %{scope: scope} do
    intent = freeze_intent!(scope)
    {:ok, _} = Billing.transition_intent(scope, intent, :enqueue_sync)

    assert {:ok, transitions} = Billing.list_intent_transitions(scope, intent)
    assert [%{event: "freeze"}, %{event: "enqueue_sync", to_state: "sync_pending"}] = transitions
  end

  test "an illegal transition does not poison an enclosing transaction (INV-015)", %{
    scope: scope
  } do
    intent = freeze_intent!(scope)

    {:ok, still_usable?} =
      Repo.transaction(fn ->
        # :book is illegal from "frozen" — the rejection must leave the
        # outer transaction healthy, exactly as the sync worker relies on.
        assert {:error, {:illegal_state, _}} =
                 Billing.transition_intent(scope, intent, :book)

        Repo.exists?(from i in InvoiceIntent, where: i.id == ^intent.id)
      end)

    assert still_usable?
    assert Billing.intent_state(intent) == "frozen"
  end
end
