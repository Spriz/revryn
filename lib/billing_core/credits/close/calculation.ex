defmodule BillingCore.Credits.Close.Calculation do
  @moduledoc """
  Pure, deterministic close arithmetic and frozen ledger membership creation.

  This module never reads projections or writes a database. Its caller locks
  the relevant rows, supplies the balance at the frozen cutoff, and persists
  its result atomically with the memberships and report evidence.
  """

  alias BillingCore.Domain.Canonical

  @type snapshot :: %{
          opening_minor: non_neg_integer(),
          closing_minor: non_neg_integer(),
          net_change_minor: integer(),
          economic_liability_line_minor: integer(),
          ledger_transaction_count: non_neg_integer(),
          ledger_snapshot_hash: String.t(),
          memberships: [map()],
          movements: [map()],
          transactions: [map()]
        }

  @spec calculate(map()) :: {:ok, snapshot()} | {:error, term()}
  def calculate(
        %{opening_minor: opening, closing_minor: closing, transactions: transactions} = input
      )
      when is_integer(opening) and opening >= 0 and is_integer(closing) and closing >= 0 and
             is_list(transactions) do
    with {:ok, normalized} <- normalize_transactions(transactions, input),
         movements <- aggregate_movements(normalized),
         net_change = closing - opening,
         movement_change <- Enum.sum(Enum.map(movements, & &1.liability_effect_minor)),
         :ok <- ensure_continuity(net_change, movement_change) do
      membership_rows =
        normalized
        |> Enum.with_index(1)
        |> Enum.map(fn {transaction, ordinal} ->
          %{transaction_id: transaction.id, ledger_ordinal: ordinal}
        end)

      ledger_snapshot_hash = Canonical.hash(%{transactions: normalized})

      {:ok,
       %{
         opening_minor: opening,
         closing_minor: closing,
         net_change_minor: net_change,
         economic_liability_line_minor: opening - closing,
         ledger_transaction_count: length(normalized),
         ledger_snapshot_hash: ledger_snapshot_hash,
         memberships: membership_rows,
         movements: movements,
         transactions: normalized
       }}
    end
  end

  def calculate(_), do: {:error, :invalid_close_input}

  @spec liability_effect(map()) :: {:ok, {atom(), integer()}} | {:error, term()}
  def liability_effect(%{transaction_type: type, amount_minor: amount} = transaction)
      when is_integer(amount) and amount > 0 do
    case normalize_type(type) do
      :grant -> {:ok, {:grant, amount}}
      :reserve -> {:ok, {:reserve, 0}}
      :release -> {:ok, {:release, 0}}
      :apply -> {:ok, {:apply, -amount}}
      :refund -> {:ok, {:refund, -amount}}
      :expire -> {:ok, {:expire, -amount}}
      :adjust -> adjustment_effect(amount, Map.get(transaction, :metadata, %{}))
      _ -> {:error, :unknown_transaction_type}
    end
  end

  def liability_effect(_), do: {:error, :invalid_transaction}

  defp normalize_transactions(transactions, input) do
    transactions
    |> Enum.reduce_while({:ok, []}, fn transaction, {:ok, acc} ->
      transaction = map_from(transaction)

      with :ok <- ensure_currency(transaction, Map.get(input, :currency)),
           {:ok, {source_movement_type, effect}} <- liability_effect(transaction),
           movement_type <- close_movement_type(transaction, source_movement_type, input),
           {:ok, normalized} <-
             canonical_transaction(transaction, movement_type, source_movement_type, effect) do
        {:cont, {:ok, [normalized | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, &transaction_sort_key/1)

        if length(normalized) == MapSet.size(MapSet.new(normalized, & &1.id)),
          do: {:ok, normalized},
          else: {:error, :duplicate_transaction_id}

      error ->
        error
    end)
  end

  defp ensure_currency(_transaction, nil), do: :ok
  defp ensure_currency(%{currency: currency}, currency), do: :ok
  defp ensure_currency(_, _), do: {:error, :currency_mismatch}

  defp canonical_transaction(transaction, movement_type, source_movement_type, effect) do
    case Map.get(transaction, :id) do
      id when is_binary(id) ->
        {:ok,
         %{
           id: id,
           transaction_type: Atom.to_string(normalize_type(transaction.transaction_type)),
           movement_type: Atom.to_string(movement_type),
           source_movement_type: Atom.to_string(source_movement_type),
           amount_minor: transaction.amount_minor,
           liability_effect_minor: effect,
           currency: Map.get(transaction, :currency),
           accounting_effective_on: Map.get(transaction, :accounting_effective_on),
           occurred_at: Map.get(transaction, :occurred_at),
           credit_account_id: Map.get(transaction, :credit_account_id),
           grant_id: Map.get(transaction, :grant_id),
           reason_code: Map.get(transaction, :reason_code),
           metadata: Map.get(transaction, :metadata, %{})
         }}

      _ ->
        {:error, :transaction_id_required}
    end
  end

  defp transaction_sort_key(transaction) do
    {
      date_key(transaction.accounting_effective_on),
      datetime_key(transaction.occurred_at),
      transaction.id
    }
  end

  defp date_key(%Date{} = value), do: Date.to_iso8601(value)
  defp date_key(value) when is_binary(value), do: value
  defp date_key(_), do: ""

  defp datetime_key(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime_key(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime_key(value) when is_binary(value), do: value
  defp datetime_key(_), do: ""

  defp aggregate_movements(transactions) do
    transactions
    |> Enum.group_by(& &1.movement_type)
    |> Enum.map(fn {movement_type, rows} ->
      %{
        movement_type: movement_type_atom(movement_type),
        amount_minor: Enum.sum(Enum.map(rows, & &1.amount_minor)),
        liability_effect_minor: Enum.sum(Enum.map(rows, & &1.liability_effect_minor)),
        transaction_count: length(rows),
        contra_account_number: nil
      }
    end)
    |> Enum.sort_by(&Atom.to_string(&1.movement_type))
  end

  defp ensure_continuity(change, change), do: :ok
  defp ensure_continuity(_expected, _actual), do: {:error, :ledger_divergence}

  defp adjustment_effect(amount, metadata) do
    case Map.get(metadata, "direction") || Map.get(metadata, :direction) do
      "increase" -> {:ok, {:positive_adjustment, amount}}
      :increase -> {:ok, {:positive_adjustment, amount}}
      "decrease" -> {:ok, {:negative_adjustment, -amount}}
      :decrease -> {:ok, {:negative_adjustment, -amount}}
      _ -> {:error, :invalid_adjustment_direction}
    end
  end

  defp map_from(%_{} = struct), do: Map.from_struct(struct)
  defp map_from(map) when is_map(map), do: map

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type("grant"), do: :grant
  defp normalize_type("reserve"), do: :reserve
  defp normalize_type("release"), do: :release
  defp normalize_type("apply"), do: :apply
  defp normalize_type("refund"), do: :refund
  defp normalize_type("expire"), do: :expire
  defp normalize_type("adjust"), do: :adjust
  defp normalize_type(_), do: :unknown

  defp movement_type_atom("grant"), do: :grant
  defp movement_type_atom("reserve"), do: :reserve
  defp movement_type_atom("release"), do: :release
  defp movement_type_atom("apply"), do: :apply
  defp movement_type_atom("refund"), do: :refund
  defp movement_type_atom("expire"), do: :expire
  defp movement_type_atom("positive_adjustment"), do: :positive_adjustment
  defp movement_type_atom("negative_adjustment"), do: :negative_adjustment
  defp movement_type_atom("prior_period_adjustment"), do: :prior_period_adjustment

  # Late ledger facts belong to the current close even if their assigned
  # accounting date lies in the earlier month. The caller supplies the prior
  # frozen cutoff; no code path may mutate the previous membership instead.
  defp close_movement_type(transaction, source_movement_type, input) do
    cond do
      prior_period_adjustment?(
        transaction,
        Map.get(input, :period_start),
        Map.get(input, :previous_transaction_cutoff)
      ) ->
        :prior_period_adjustment

      # An explicitly approved late transaction from an already-closed
      # period is included as a prior-period adjustment, never silently
      # (BC-US-165); the caller records the approval in the audit trail.
      Map.get(transaction, :id) in Map.get(input, :approved_prior_period_transaction_ids, []) ->
        :prior_period_adjustment

      true ->
        source_movement_type
    end
  end

  defp prior_period_adjustment?(
         %{accounting_effective_on: effective_on, occurred_at: occurred_at},
         %Date{} = period_start,
         %DateTime{} = cutoff
       ) do
    date_before?(effective_on, period_start) and datetime_after?(occurred_at, cutoff)
  end

  defp prior_period_adjustment?(_, _, _), do: false

  defp date_before?(%Date{} = left, %Date{} = right), do: Date.compare(left, right) == :lt
  defp date_before?(left, %Date{} = right) when is_binary(left), do: left < Date.to_iso8601(right)
  defp date_before?(_, _), do: false

  defp datetime_after?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :gt

  defp datetime_after?(left, %DateTime{} = right) when is_binary(left),
    do: left > DateTime.to_iso8601(right)

  defp datetime_after?(_, _), do: false
end
