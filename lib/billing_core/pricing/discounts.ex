defmodule BillingCore.Pricing.Discounts do
  @moduledoc """
  Discount application engine (SPEC §10.7–§10.9).

  `apply_discounts/2` takes the eligible charge lines
  (`BillingCore.Pricing.EligibleLine`) and the discount definitions
  (`BillingCore.Pricing.PercentageDiscount` /
  `BillingCore.Pricing.FixedDiscount`) and applies them in the documented
  order (SPEC §10.7):

    1. **all** percentage discounts, in ascending `priority` order with ties
       broken by discount `id`; each computes on the current running eligible
       base — the line amounts after all previously applied discounts;
    2. **all** fixed discounts, in the same stable order; each allocates
       across eligible lines proportionally to their current post-discount
       amounts via `Money.allocate!/2` (largest remainder, stable line-id
       tie-break, SPEC §9.3, §10.9);
    3. the non-negative invoice floor: total discounts never exceed the
       eligible base — a fixed discount that would cross zero is clamped to
       the remaining base, and a 100% percentage discount produces exactly
       zero, never a negative total.

  Percentage discount amounts are computed exactly on the running base and
  rounded once at the currency boundary (`Money.round_major/2`), then
  allocated across lines like fixed discounts, so the allocations of one
  discount always sum exactly to its (possibly clamped) amount (SPEC §23.3).

  Discounts materialize as negative lines per adjusted source line
  (SPEC §10.8): each `BillingCore.Pricing.DiscountLine` carries the source
  line reference plus its service period and recognition mode so the caller
  can copy metadata (SPEC §9.4). Lines whose allocation is zero are not
  materialized.
  """

  alias BillingCore.Domain.{Money, Period}

  alias BillingCore.Pricing.{
    DiscountLine,
    Discounts.Result,
    EligibleLine,
    FixedDiscount,
    PercentageDiscount,
    Schema
  }

  alias Decimal, as: D

  @doc """
  Applies `discounts` to `lines` per SPEC §10.7–§10.9. Returns
  `{:ok, %BillingCore.Pricing.Discounts.Result{}}` or `{:error, term}`.
  """
  @spec apply_discounts([EligibleLine.t()], [PercentageDiscount.t() | FixedDiscount.t()]) ::
          {:ok, Result.t()} | {:error, term()}
  def apply_discounts(lines, discounts) when is_list(lines) and is_list(discounts) do
    with :ok <- validate_lines(lines),
         currency = hd(lines).amount.currency,
         :ok <- validate_discounts(discounts, currency) do
      {:ok, run(lines, discounts, currency)}
    end
  end

  def apply_discounts(lines, discounts), do: {:error, {:invalid_input, lines, discounts}}

  ## Application

  defp run(lines, discounts, currency) do
    by_id = Map.new(lines, &{&1.id, &1})
    initial = Enum.map(lines, &{&1.id, &1.amount.minor_units})
    gross_minor = current_total(initial)

    {percentages, fixed} = Enum.split_with(discounts, &is_struct(&1, PercentageDiscount))

    ordered =
      Enum.sort_by(percentages, &{&1.priority, &1.id}) ++
        Enum.sort_by(fixed, &{&1.priority, &1.id})

    {final, applied_traces, discount_lines} =
      Enum.reduce(ordered, {initial, [], []}, fn discount, {current, traces, line_groups} ->
        {new_current, trace, new_lines} = apply_one(discount, current, currency, by_id)
        {new_current, [trace | traces], [new_lines | line_groups]}
      end)

    net_minor = current_total(final)

    %Result{
      discount_lines: discount_lines |> Enum.reverse() |> Enum.concat(),
      line_totals: Enum.map(final, fn {id, minor} -> {id, Money.new!(currency, minor)} end),
      gross_total: Money.new!(currency, gross_minor),
      net_total: Money.new!(currency, net_minor),
      trace: %{
        "currency" => currency,
        "gross_minor" => gross_minor,
        "net_minor" => net_minor,
        "discounts" => Enum.reverse(applied_traces)
      }
    }
  end

  # Percentage discount (SPEC §10.7 step 3): exact amount on the running
  # base, rounded once at the currency boundary, then allocated.
  defp apply_one(%PercentageDiscount{} = discount, current, currency, by_id) do
    base_minor = current_total(current)
    base_major = Money.to_major_decimal(Money.new!(currency, base_minor))
    fraction = D.div(D.new(discount.basis_points), D.new(10_000))
    exact_major = D.mult(base_major, fraction)
    rounded = Money.round_major(exact_major, currency)
    # bp <= 10000 already bounds the exact amount by the base; min is a guard.
    amount_minor = min(rounded.minor_units, base_minor)

    trace = %{
      "discount_id" => discount.id,
      "type" => "percentage",
      "basis_points" => discount.basis_points,
      "priority" => discount.priority,
      "base_minor" => base_minor,
      "exact_amount" => Schema.decimal_string(exact_major),
      "rounding_delta_minor" =>
        Schema.decimal_string(Money.rounding_delta_minor(exact_major, currency)),
      "amount_minor" => amount_minor
    }

    allocate(discount, amount_minor, current, currency, by_id, trace)
  end

  # Fixed discount (SPEC §10.7 steps 4–5): clamped to the remaining base.
  defp apply_one(%FixedDiscount{} = discount, current, currency, by_id) do
    base_minor = current_total(current)
    amount_minor = min(discount.amount_minor, base_minor)

    trace = %{
      "discount_id" => discount.id,
      "type" => "fixed",
      "priority" => discount.priority,
      "base_minor" => base_minor,
      "requested_minor" => discount.amount_minor,
      "clamped" => amount_minor < discount.amount_minor,
      "amount_minor" => amount_minor
    }

    allocate(discount, amount_minor, current, currency, by_id, trace)
  end

  defp allocate(_discount, amount_minor, current, _currency, _by_id, trace)
       when amount_minor <= 0 do
    {current, Map.put(trace, "allocations", []), []}
  end

  defp allocate(discount, amount_minor, current, currency, by_id, trace) do
    current_map = Map.new(current)
    weights = Enum.map(current, fn {id, minor} -> {id, D.new(minor)} end)
    allocations = Money.allocate!(Money.new!(currency, amount_minor), weights)
    allocation_by_id = Map.new(allocations, fn {id, money} -> {id, money.minor_units} end)

    new_current =
      Enum.map(current, fn {id, minor} -> {id, minor - Map.fetch!(allocation_by_id, id)} end)

    allocation_trace =
      Enum.map(allocations, fn {id, money} ->
        %{"line_id" => id, "amount_minor" => -money.minor_units}
      end)

    lines =
      for {id, money} <- allocations, money.minor_units != 0 do
        source = Map.fetch!(by_id, id)

        %DiscountLine{
          discount_id: discount.id,
          source_line_id: id,
          allocation: Money.negate(money),
          service_period: source.service_period,
          recognition_mode: source.recognition_mode,
          trace: %{
            "discount_id" => discount.id,
            "discount_type" => trace["type"],
            "source_line_id" => id,
            "discount_amount_minor" => trace["amount_minor"],
            "source_base_minor" => Map.fetch!(current_map, id),
            "allocation_minor" => -money.minor_units
          }
        }
      end

    {new_current, Map.put(trace, "allocations", allocation_trace), lines}
  end

  defp current_total(current), do: current |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  ## Validation

  defp validate_lines([]), do: {:error, :no_eligible_lines}

  defp validate_lines(lines) do
    cond do
      not Enum.all?(lines, &valid_line_shape?/1) ->
        {:error, {:invalid_line, Enum.find(lines, &(not valid_line_shape?(&1)))}}

      Enum.any?(lines, &(&1.amount.minor_units < 0)) ->
        {:error, {:negative_line_amount, Enum.find(lines, &(&1.amount.minor_units < 0)).id}}

      lines |> Enum.map(& &1.id) |> Enum.uniq() |> length() != length(lines) ->
        {:error, :duplicate_line_ids}

      lines |> Enum.map(& &1.amount.currency) |> Enum.uniq() |> length() > 1 ->
        {:error, :mixed_currencies}

      true ->
        :ok
    end
  end

  defp valid_line_shape?(%EligibleLine{id: id, amount: %Money{}} = line) do
    is_binary(id) and id != "" and
      (is_nil(line.service_period) or is_struct(line.service_period, Period))
  end

  defp valid_line_shape?(_other), do: false

  defp validate_discounts(discounts, currency) do
    Enum.reduce_while(discounts, :ok, fn discount, :ok ->
      case validate_discount(discount, currency) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_discount(%PercentageDiscount{id: id, basis_points: bp, priority: p}, _currency) do
    cond do
      not (is_binary(id) and id != "") -> {:error, {:invalid_discount_id, id}}
      not (is_integer(bp) and bp in 0..10_000) -> {:error, {:invalid_basis_points, id}}
      not is_integer(p) -> {:error, {:invalid_priority, id}}
      true -> :ok
    end
  end

  defp validate_discount(%FixedDiscount{} = discount, currency) do
    %FixedDiscount{id: id, amount_minor: amount, currency: discount_currency, priority: p} =
      discount

    cond do
      not (is_binary(id) and id != "") -> {:error, {:invalid_discount_id, id}}
      not (is_integer(amount) and amount > 0) -> {:error, {:invalid_fixed_amount, id}}
      discount_currency != currency -> {:error, {:discount_currency_mismatch, id}}
      not is_integer(p) -> {:error, {:invalid_priority, id}}
      true -> :ok
    end
  end

  defp validate_discount(other, _currency), do: {:error, {:invalid_discount, other}}
end
