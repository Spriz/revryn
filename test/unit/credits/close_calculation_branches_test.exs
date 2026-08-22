defmodule BillingCore.Credits.Close.CalculationBranchesTest do
  @moduledoc """
  Branch coverage for `BillingCore.Credits.Close.Calculation` beyond the
  happy paths in `close_calculation_test.exs`: every typed liability effect
  clause, input validation failures, and the normalization edge branches.
  All amounts are integer minor units.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Credits.Close.Calculation
  alias BillingCore.Credits.CreditTransaction

  describe "liability_effect/1 per transaction type" do
    test "grant increases liability by the full amount" do
      assert {:ok, {:grant, 100}} =
               Calculation.liability_effect(%{transaction_type: :grant, amount_minor: 100})
    end

    test "reserve and release move balance between buckets with zero liability effect" do
      assert {:ok, {:reserve, 0}} =
               Calculation.liability_effect(%{transaction_type: :reserve, amount_minor: 40})

      assert {:ok, {:release, 0}} =
               Calculation.liability_effect(%{transaction_type: :release, amount_minor: 40})
    end

    test "apply, refund, and expire reduce liability by the full amount" do
      assert {:ok, {:apply, -30}} =
               Calculation.liability_effect(%{transaction_type: :apply, amount_minor: 30})

      assert {:ok, {:refund, -10}} =
               Calculation.liability_effect(%{transaction_type: :refund, amount_minor: 10})

      assert {:ok, {:expire, -5}} =
               Calculation.liability_effect(%{transaction_type: :expire, amount_minor: 5})
    end

    test "adjust maps direction metadata to signed adjustment movements" do
      assert {:ok, {:positive_adjustment, 20}} =
               Calculation.liability_effect(%{
                 transaction_type: :adjust,
                 amount_minor: 20,
                 metadata: %{"direction" => "increase"}
               })

      assert {:ok, {:positive_adjustment, 20}} =
               Calculation.liability_effect(%{
                 transaction_type: :adjust,
                 amount_minor: 20,
                 metadata: %{direction: :increase}
               })

      assert {:ok, {:negative_adjustment, -20}} =
               Calculation.liability_effect(%{
                 transaction_type: :adjust,
                 amount_minor: 20,
                 metadata: %{"direction" => "decrease"}
               })

      assert {:ok, {:negative_adjustment, -20}} =
               Calculation.liability_effect(%{
                 transaction_type: :adjust,
                 amount_minor: 20,
                 metadata: %{direction: :decrease}
               })
    end

    test "adjust without a valid direction is a typed error, never a silent sign guess" do
      assert {:error, :invalid_adjustment_direction} =
               Calculation.liability_effect(%{
                 transaction_type: :adjust,
                 amount_minor: 20,
                 metadata: %{}
               })

      assert {:error, :invalid_adjustment_direction} =
               Calculation.liability_effect(%{
                 transaction_type: :adjust,
                 amount_minor: 20,
                 metadata: %{"direction" => "sideways"}
               })
    end

    test "unknown transaction types are a typed error (atom and string spellings)" do
      assert {:error, :unknown_transaction_type} =
               Calculation.liability_effect(%{transaction_type: :chargeback, amount_minor: 10})

      assert {:error, :unknown_transaction_type} =
               Calculation.liability_effect(%{transaction_type: "chargeback", amount_minor: 10})
    end

    test "non-positive, non-integer, or absent amounts are invalid transactions" do
      assert {:error, :invalid_transaction} =
               Calculation.liability_effect(%{transaction_type: :grant, amount_minor: 0})

      assert {:error, :invalid_transaction} =
               Calculation.liability_effect(%{transaction_type: :grant, amount_minor: -5})

      assert {:error, :invalid_transaction} =
               Calculation.liability_effect(%{transaction_type: :grant, amount_minor: "100"})

      assert {:error, :invalid_transaction} = Calculation.liability_effect(%{})
    end
  end

  describe "calculate/1 input validation" do
    test "rejects negative or non-integer balances and non-list ledgers" do
      assert {:error, :invalid_close_input} =
               Calculation.calculate(%{opening_minor: -1, closing_minor: 0, transactions: []})

      assert {:error, :invalid_close_input} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: Decimal.new(10),
                 transactions: []
               })

      assert {:error, :invalid_close_input} =
               Calculation.calculate(%{opening_minor: 0, closing_minor: 0, transactions: nil})

      assert {:error, :invalid_close_input} = Calculation.calculate(%{})
    end

    test "halts on a transaction from another currency" do
      assert {:error, :currency_mismatch} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 100,
                 currency: "DKK",
                 transactions: [transaction("tx-1", :grant, 100, currency: "EUR")]
               })
    end

    test "halts on a transaction missing its currency when the close has one" do
      tx = Map.delete(transaction("tx-1", :grant, 100), :currency)

      assert {:error, :currency_mismatch} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 100,
                 currency: "DKK",
                 transactions: [tx]
               })
    end

    test "skips the currency check entirely when the close carries no currency" do
      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 150,
                 transactions: [
                   transaction("tx-1", :grant, 100, currency: "DKK"),
                   transaction("tx-2", :grant, 50, currency: "EUR")
                 ]
               })

      assert snapshot.net_change_minor == 150
    end

    test "rejects duplicate transaction IDs after normalization" do
      assert {:error, :duplicate_transaction_id} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 100,
                 transactions: [
                   transaction("tx-dup", :grant, 50),
                   transaction("tx-dup", :grant, 50)
                 ]
               })
    end

    test "rejects transactions without a binary ID" do
      assert {:error, :transaction_id_required} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 100,
                 transactions: [transaction(nil, :grant, 100)]
               })
    end

    test "propagates typed per-transaction errors instead of freezing a snapshot" do
      assert {:error, :invalid_transaction} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 0,
                 transactions: [transaction("tx-1", :grant, 0)]
               })

      assert {:error, :unknown_transaction_type} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 0,
                 transactions: [transaction("tx-1", :chargeback, 10)]
               })

      assert {:error, :invalid_adjustment_direction} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 10,
                 transactions: [transaction("tx-1", :adjust, 10)]
               })
    end
  end

  describe "calculate/1 normalization" do
    test "aggregates every string-typed movement with exact integer arithmetic" do
      transactions = [
        transaction("tx-1", "grant", 100, effective_on: ~D[2026-07-01]),
        transaction("tx-2", "reserve", 20, effective_on: ~D[2026-07-02]),
        transaction("tx-3", "release", 20, effective_on: ~D[2026-07-03]),
        transaction("tx-4", "apply", 30, effective_on: ~D[2026-07-04]),
        transaction("tx-5", "refund", 10, effective_on: ~D[2026-07-05]),
        transaction("tx-6", "expire", 5, effective_on: ~D[2026-07-06]),
        transaction("tx-7", "adjust", 20,
          effective_on: ~D[2026-07-07],
          metadata: %{"direction" => "increase"}
        ),
        transaction("tx-8", "adjust", 15,
          effective_on: ~D[2026-07-08],
          metadata: %{"direction" => "decrease"}
        )
      ]

      # 100 - 30 - 10 - 5 + 20 - 15 = 60
      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 40,
                 closing_minor: 100,
                 currency: "DKK",
                 transactions: transactions
               })

      assert snapshot.net_change_minor == 60
      assert snapshot.economic_liability_line_minor == -60
      assert snapshot.ledger_transaction_count == 8

      assert Enum.map(snapshot.movements, &{&1.movement_type, &1.liability_effect_minor}) == [
               {:apply, -30},
               {:expire, -5},
               {:grant, 100},
               {:negative_adjustment, -15},
               {:positive_adjustment, 20},
               {:refund, -10},
               {:release, 0},
               {:reserve, 0}
             ]

      assert Enum.all?(snapshot.movements, &(&1.transaction_count == 1))
      assert Enum.all?(snapshot.movements, &is_nil(&1.contra_account_number))
    end

    test "accepts CreditTransaction structs, not only plain maps" do
      struct = %CreditTransaction{
        id: "00000000-0000-0000-0000-00000000aa01",
        transaction_type: :grant,
        amount_minor: 50,
        currency: "DKK",
        accounting_effective_on: ~D[2026-07-01],
        occurred_at: ~U[2026-07-01 09:00:00Z]
      }

      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 50,
                 currency: "DKK",
                 transactions: [struct]
               })

      assert [detail] = snapshot.transactions
      assert detail.id == struct.id
      assert detail.transaction_type == "grant"
      assert detail.liability_effect_minor == 50
    end

    test "orders deterministically across Date/DateTime, ISO strings, naive, and missing keys" do
      transactions = [
        # Missing dates sort first ("" keys), tie-broken by ID.
        transaction("tx-b", :grant, 10, effective_on: nil, occurred_at: nil),
        transaction("tx-a", :grant, 10, effective_on: nil, occurred_at: nil),
        transaction("tx-c", :grant, 10,
          effective_on: "2026-07-01",
          occurred_at: "2026-07-01T10:00:00Z"
        ),
        transaction("tx-d", :grant, 10,
          effective_on: ~D[2026-07-02],
          occurred_at: ~N[2026-07-02 10:00:00]
        )
      ]

      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 40,
                 currency: "DKK",
                 transactions: transactions
               })

      assert Enum.map(snapshot.memberships, & &1.transaction_id) ==
               ["tx-a", "tx-b", "tx-c", "tx-d"]

      assert Enum.map(snapshot.memberships, & &1.ledger_ordinal) == [1, 2, 3, 4]
    end

    test "identical ledgers freeze to identical snapshot hashes; different ledgers differ" do
      input = %{
        opening_minor: 0,
        closing_minor: 100,
        currency: "DKK",
        transactions: [transaction("tx-1", :grant, 100)]
      }

      assert {:ok, one} = Calculation.calculate(input)
      assert {:ok, two} = Calculation.calculate(input)
      assert one.ledger_snapshot_hash == two.ledger_snapshot_hash

      assert {:ok, other} =
               Calculation.calculate(%{
                 input
                 | transactions: [transaction("tx-2", :grant, 100)]
               })

      refute other.ledger_snapshot_hash == one.ledger_snapshot_hash
    end
  end

  describe "calculate/1 prior-period classification" do
    test "string-dated late backdated facts are prior-period adjustments in this close" do
      late =
        transaction("tx-late", :apply, 30,
          effective_on: "2026-06-30",
          occurred_at: "2026-07-02T02:00:00Z"
        )

      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 100,
                 closing_minor: 70,
                 currency: "DKK",
                 period_start: ~D[2026-07-01],
                 previous_transaction_cutoff: ~U[2026-07-01 00:00:00Z],
                 transactions: [late]
               })

      assert [detail] = snapshot.transactions
      assert detail.movement_type == "prior_period_adjustment"
      assert detail.source_movement_type == "apply"
    end

    test "explicitly approved prior-period transactions reclassify without a cutoff match" do
      approved =
        transaction("tx-approved", :grant, 25,
          effective_on: ~D[2026-07-05],
          occurred_at: ~U[2026-07-05 10:00:00Z]
        )

      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 25,
                 currency: "DKK",
                 approved_prior_period_transaction_ids: ["tx-approved"],
                 transactions: [approved]
               })

      assert [movement] = snapshot.movements
      assert movement.movement_type == :prior_period_adjustment
      assert movement.liability_effect_minor == 25

      assert [detail] = snapshot.transactions
      assert detail.source_movement_type == "grant"
    end

    test "in-period facts stay on their source movement when a cutoff is supplied" do
      in_period =
        transaction("tx-in", :grant, 25,
          effective_on: ~D[2026-07-05],
          occurred_at: ~U[2026-07-05 10:00:00Z]
        )

      assert {:ok, snapshot} =
               Calculation.calculate(%{
                 opening_minor: 0,
                 closing_minor: 25,
                 currency: "DKK",
                 period_start: ~D[2026-07-01],
                 previous_transaction_cutoff: ~U[2026-07-01 00:00:00Z],
                 transactions: [in_period]
               })

      assert [movement] = snapshot.movements
      assert movement.movement_type == :grant
    end
  end

  defp transaction(id, type, amount, opts \\ []) do
    %{
      id: id,
      credit_account_id: "00000000-0000-0000-0000-000000000099",
      transaction_type: type,
      amount_minor: amount,
      currency: Keyword.get(opts, :currency, "DKK"),
      accounting_effective_on: Keyword.get(opts, :effective_on, ~D[2026-07-01]),
      occurred_at: Keyword.get(opts, :occurred_at, ~U[2026-07-01 10:00:00Z]),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
