defmodule BillingCore.Credits.Close.CalculationTest do
  use ExUnit.Case, async: true

  alias BillingCore.Credits.Close.Calculation

  test "freezes deterministic memberships and exact debit-positive liability arithmetic" do
    transactions = [
      transaction(
        "00000000-0000-0000-0000-000000000002",
        :apply,
        30,
        ~D[2026-07-02],
        ~U[2026-07-02 10:00:00Z]
      ),
      transaction(
        "00000000-0000-0000-0000-000000000001",
        :grant,
        100,
        ~D[2026-07-01],
        ~U[2026-07-01 10:00:00Z]
      ),
      transaction(
        "00000000-0000-0000-0000-000000000003",
        :reserve,
        20,
        ~D[2026-07-03],
        ~U[2026-07-03 10:00:00Z]
      )
    ]

    assert {:ok, snapshot} =
             Calculation.calculate(%{
               opening_minor: 0,
               closing_minor: 70,
               currency: "DKK",
               transactions: Enum.reverse(transactions)
             })

    assert snapshot.net_change_minor == 70
    assert snapshot.economic_liability_line_minor == -70
    assert snapshot.ledger_transaction_count == 3

    assert snapshot.memberships == [
             %{transaction_id: "00000000-0000-0000-0000-000000000001", ledger_ordinal: 1},
             %{transaction_id: "00000000-0000-0000-0000-000000000002", ledger_ordinal: 2},
             %{transaction_id: "00000000-0000-0000-0000-000000000003", ledger_ordinal: 3}
           ]

    assert Enum.map(snapshot.movements, &{&1.movement_type, &1.liability_effect_minor}) ==
             [{:apply, -30}, {:grant, 100}, {:reserve, 0}]
  end

  test "late backdated transaction stays in the current close as a prior-period adjustment" do
    late_apply =
      transaction(
        "00000000-0000-0000-0000-000000000004",
        :apply,
        30,
        ~D[2026-06-30],
        ~U[2026-07-02 02:00:00Z]
      )

    assert {:ok, snapshot} =
             Calculation.calculate(%{
               opening_minor: 100,
               closing_minor: 70,
               currency: "DKK",
               period_start: ~D[2026-07-01],
               previous_transaction_cutoff: ~U[2026-07-01 00:00:00Z],
               transactions: [late_apply]
             })

    assert snapshot.memberships == [
             %{transaction_id: late_apply.id, ledger_ordinal: 1}
           ]

    assert snapshot.movements == [
             %{
               movement_type: :prior_period_adjustment,
               amount_minor: 30,
               liability_effect_minor: -30,
               transaction_count: 1,
               contra_account_number: nil
             }
           ]

    assert [detail] = snapshot.transactions
    assert detail.transaction_type == "apply"
    assert detail.source_movement_type == "apply"
    assert detail.movement_type == "prior_period_adjustment"
    assert detail.liability_effect_minor == -30
  end

  test "rejects ledger totals that do not bridge opening to closing" do
    assert {:error, :ledger_divergence} =
             Calculation.calculate(%{
               opening_minor: 0,
               closing_minor: 50,
               transactions: [
                 transaction(
                   "00000000-0000-0000-0000-000000000005",
                   :grant,
                   10,
                   ~D[2026-07-01],
                   ~U[2026-07-01 10:00:00Z]
                 )
               ]
             })
  end

  defp transaction(id, type, amount, effective_on, occurred_at) do
    %{
      id: id,
      credit_account_id: "00000000-0000-0000-0000-000000000099",
      transaction_type: type,
      amount_minor: amount,
      currency: "DKK",
      accounting_effective_on: effective_on,
      occurred_at: occurred_at,
      metadata: %{}
    }
  end
end
