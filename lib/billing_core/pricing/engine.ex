defmodule BillingCore.Pricing.Engine do
  @moduledoc """
  Pure rating engine for the seven pricing models (SPEC §10.1–§10.6).

  `rate/1` takes a `BillingCore.Pricing.RatingRequest` and returns
  `{:ok, %BillingCore.Pricing.ChargeResult{}}` or `{:error, term}`. Exactly
  one currency rounding happens per line, at the end, via
  `Money.round_major/2` (half-away-from-zero, SPEC §9.3); the recorded
  rounding delta comes from the same boundary
  (`Money.rounding_delta_minor/2`, INV-012).

  ## Precision model

  All arithmetic is `Decimal`; the engine assumes a validated pricing model
  (`BillingCore.Pricing.Model.from_map/1`). The only division in the engine
  is proration (SPEC §10.1), computed numerator-first with a single division
  last:

      unrounded = (unit_price × quantity × active_days) / period_days

  at a fixed absolute scale of 20 decimal places, half-away-from-zero,
  returning the exact quotient whenever it terminates. Dividing last at a
  fixed absolute scale makes linear fixed pricing additive under period
  splits: rating two adjacent parts of a full period sums to exactly the same
  unrounded total as rating the whole period (SPEC §23.3). Package ceilings
  use exact integer arithmetic and involve no decimal division.

  ## Proration

  Proration applies only to `FixedRecurring` (SPEC §10.1). For all other
  models the request periods are carried into the trace as line metadata
  only. `active_period` defaults to `full_period` and must be covered by it.

  ## Minimum commit (SPEC §10.6)

  Modeled as a wrapper struct `MinimumCommit{minimum_amount_minor, inner}`.
  The comparison `max(rated, minimum)` happens on the exact unrounded inner
  amount versus the exact minimum (minor units are exact at currency scale),
  and the final amount is rounded once — preserving the single-rounding
  boundary. The trace exposes `minimum_uplift`, `minimum_applied`, and the
  full inner trace.

  ## Credits and mid-period changes (SPEC §10.11, §23.3)

  A mid-period plan change is two `rate/1` calls over the remaining service
  period: `negate/1` of the old plan's result (the credit) plus the new
  plan's charge. Half-away-from-zero rounding is symmetric, so a credit line
  plus its original is always exactly zero minor units.
  """

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.Pricing.{ChargeResult, RatingRequest, Schema, Tier}

  alias BillingCore.Pricing.Model.{
    FixedRecurring,
    GraduatedTier,
    MinimumCommit,
    OneTime,
    Package,
    StandardMetered,
    VolumeTier
  }

  alias Decimal, as: D

  @rating_scale 20

  @doc """
  Rates one charge line. See the moduledoc for the calculation rules per
  model (SPEC §10.1–§10.6) and the trace contract (INV-012).
  """
  @spec rate(RatingRequest.t()) :: {:ok, ChargeResult.t()} | {:error, term()}
  def rate(%RatingRequest{} = request) do
    with :ok <- validate_request(request) do
      do_rate(request.pricing, request)
    end
  end

  def rate(other), do: {:error, {:invalid_request, other}}

  @doc """
  Negates a rated result into its exact credit (SPEC §10.11, §23.3): the
  amount, unrounded amount, and rounding delta are negated and the trace is
  marked `"negated" => true`. Because currency rounding is
  half-away-from-zero (symmetric), `negate(result).amount` always equals the
  amount obtained by rounding the negated unrounded value, and credit plus
  original is exactly zero minor units.
  """
  @spec negate(ChargeResult.t()) :: ChargeResult.t()
  def negate(%ChargeResult{} = result) do
    unrounded = D.negate(result.unrounded)
    amount = Money.negate(result.amount)

    trace =
      Map.merge(result.trace, %{
        "negated" => true,
        "amount_minor" => amount.minor_units,
        "unrounded_amount" => Schema.decimal_string(unrounded),
        "rounding_delta_minor" =>
          Schema.decimal_string(Money.rounding_delta_minor(unrounded, amount.currency))
      })

    %ChargeResult{amount: amount, unrounded: unrounded, trace: trace}
  end

  ## Request validation

  defp validate_request(%RatingRequest{} = request) do
    cond do
      not Money.valid_currency?(request.currency) ->
        {:error, {:invalid_currency, request.currency}}

      not is_struct(request.quantity, D) ->
        {:error, {:invalid_quantity, request.quantity}}

      not (is_nil(request.full_period) or is_struct(request.full_period, Period)) ->
        {:error, :invalid_full_period}

      not (is_nil(request.active_period) or is_struct(request.active_period, Period)) ->
        {:error, :invalid_active_period}

      not is_nil(request.active_period) and is_nil(request.full_period) ->
        {:error, :active_period_without_full_period}

      not is_nil(request.active_period) and
          not Period.covers?(request.full_period, request.active_period) ->
        {:error, :active_period_not_covered}

      true ->
        :ok
    end
  end

  ## Per-model rating

  # Fixed recurring (SPEC §10.1).
  defp do_rate(%FixedRecurring{unit_price: price}, request) do
    {unrounded, proration} = prorated_amount(price, request)

    finalize(unrounded, request, "fixed_recurring", %{
      "unit_price" => Schema.decimal_string(price),
      "proration" => Schema.decimal_string(proration)
    })
  end

  # One-time charge: fixed amount × quantity (usually 1).
  defp do_rate(%OneTime{unit_price: price}, request) do
    finalize(D.mult(price, request.quantity), request, "one_time", %{
      "unit_price" => Schema.decimal_string(price)
    })
  end

  # Standard metered (SPEC §10.2): aggregated_quantity × unit_rate.
  defp do_rate(%StandardMetered{unit_rate: rate}, request) do
    finalize(D.mult(request.quantity, rate), request, "standard_metered", %{
      "unit_rate" => Schema.decimal_string(rate)
    })
  end

  # Volume tiers (SPEC §10.3): Q × selected_tier.unit_rate + flat_fee.
  defp do_rate(%VolumeTier{tiers: tiers}, request) do
    with :ok <- require_non_negative_quantity(request.quantity, "volume_tier") do
      quantity = request.quantity

      case tiers
           |> Enum.with_index()
           |> Enum.find(fn {tier, _} -> Tier.contains?(tier, quantity) end) do
        nil ->
          {:error, :no_tier_contains_quantity}

        {tier, index} ->
          flat_fee = flat_fee_major(tier.flat_fee_minor, request.currency)
          unrounded = quantity |> D.mult(tier.unit_rate) |> D.add(flat_fee)

          finalize(unrounded, request, "volume_tier", %{
            "selected_tier_index" => index,
            "tiers" => volume_tier_rows(tiers, index, quantity, request.currency)
          })
      end
    end
  end

  # Graduated tiers (SPEC §10.4): sum over tiers of quantity_i × rate_i.
  defp do_rate(%GraduatedTier{tiers: tiers}, request) do
    with :ok <- require_non_negative_quantity(request.quantity, "graduated_tier") do
      rows =
        tiers
        |> Enum.with_index()
        |> Enum.map(fn {tier, index} ->
          graduated_row(tier, index, request.quantity, request.currency)
        end)

      unrounded = rows |> Enum.map(& &1.amount) |> Enum.reduce(D.new(0), &D.add/2)

      finalize(unrounded, request, "graduated_tier", %{"tiers" => Enum.map(rows, & &1.trace)})
    end
  end

  # Package pricing (SPEC §10.5): ceil(Q / package_size) × package_price.
  defp do_rate(%Package{package_size: size, package_price: price}, request) do
    with :ok <- require_non_negative_quantity(request.quantity, "package"),
         :ok <- require_positive(size, :invalid_package_size) do
      packages = ceil_packages(request.quantity, size)
      unrounded = D.mult(D.new(packages), price)

      finalize(unrounded, request, "package", %{
        "package_size" => Schema.decimal_string(size),
        "package_price" => Schema.decimal_string(price),
        "packages" => packages
      })
    end
  end

  # Minimum commit (SPEC §10.6): max(rated, minimum), uplift in trace.
  defp do_rate(%MinimumCommit{minimum_amount_minor: minimum}, _request)
       when not (is_integer(minimum) and minimum >= 0) do
    {:error, :invalid_minimum_amount}
  end

  defp do_rate(%MinimumCommit{inner: inner, minimum_amount_minor: minimum_minor}, request) do
    with {:ok, inner_result} <- do_rate(inner, request) do
      minimum_major = Money.to_major_decimal(Money.new!(request.currency, minimum_minor))
      rated = inner_result.unrounded

      {final, applied?} =
        if D.compare(rated, minimum_major) == :lt,
          do: {minimum_major, true},
          else: {rated, false}

      finalize(final, request, "minimum_commit", %{
        "minimum_amount_minor" => minimum_minor,
        "rated_unrounded" => Schema.decimal_string(rated),
        "minimum_applied" => applied?,
        "minimum_uplift" => Schema.decimal_string(D.sub(final, rated)),
        "inner" => inner_result.trace
      })
    end
  end

  defp do_rate(other, _request), do: {:error, {:unsupported_pricing, other}}

  ## Proration (SPEC §10.1)

  defp prorated_amount(price, %RatingRequest{full_period: nil} = request) do
    {D.mult(price, request.quantity), D.new(1)}
  end

  defp prorated_amount(price, %RatingRequest{full_period: full} = request) do
    active = request.active_period || full
    period_days = Period.days(full)
    active_days = Period.days(active)

    numerator = price |> D.mult(request.quantity) |> D.mult(D.new(active_days))

    {div_fixed_scale(numerator, period_days), div_fixed_scale(D.new(active_days), period_days)}
  end

  # Fixed-absolute-scale division by a positive integer, half-away-from-zero,
  # exact whenever the quotient terminates within the rating scale. Pure
  # integer arithmetic on the Decimal coefficient — never floats (INV-006).
  defp div_fixed_scale(%D{sign: sign, coef: coef, exp: exp}, denominator)
       when is_integer(denominator) and denominator > 0 and is_integer(coef) do
    shift = @rating_scale + exp

    {numerator, scaled_denominator} =
      if shift >= 0 do
        {coef * Integer.pow(10, shift), denominator}
      else
        {coef, denominator * Integer.pow(10, -shift)}
      end

    quotient = div(numerator, scaled_denominator)
    remainder = rem(numerator, scaled_denominator)
    rounded = if 2 * remainder >= scaled_denominator, do: quotient + 1, else: quotient

    D.normalize(D.new(sign, rounded, -@rating_scale))
  end

  ## Tier helpers

  defp volume_tier_rows(tiers, selected_index, quantity, currency) do
    tiers
    |> Enum.with_index()
    |> Enum.map(fn {tier, index} ->
      selected? = index == selected_index

      {tier_quantity, amount} =
        if selected? do
          fee = flat_fee_major(tier.flat_fee_minor, currency)
          {quantity, quantity |> D.mult(tier.unit_rate) |> D.add(fee)}
        else
          {D.new(0), D.new(0)}
        end

      %{
        "index" => index,
        "from" => Schema.decimal_string(tier.from),
        "to" => tier.to && Schema.decimal_string(tier.to),
        "unit_rate" => Schema.decimal_string(tier.unit_rate),
        "flat_fee_minor" => tier.flat_fee_minor,
        "quantity" => Schema.decimal_string(tier_quantity),
        "amount" => Schema.decimal_string(amount),
        "selected" => selected?
      }
    end)
  end

  defp graduated_row(tier, index, quantity, currency) do
    capped = if tier.to, do: D.min(quantity, tier.to), else: quantity
    tier_quantity = D.max(D.new(0), D.sub(capped, tier.from))

    flat_fee =
      if D.compare(tier_quantity, D.new(0)) == :gt,
        do: flat_fee_major(tier.flat_fee_minor, currency),
        else: D.new(0)

    amount = tier_quantity |> D.mult(tier.unit_rate) |> D.add(flat_fee)

    %{
      quantity: tier_quantity,
      amount: amount,
      trace: %{
        "index" => index,
        "from" => Schema.decimal_string(tier.from),
        "to" => tier.to && Schema.decimal_string(tier.to),
        "unit_rate" => Schema.decimal_string(tier.unit_rate),
        "flat_fee_minor" => tier.flat_fee_minor,
        "quantity" => Schema.decimal_string(tier_quantity),
        "amount" => Schema.decimal_string(amount)
      }
    }
  end

  # ceil(Q / package_size) as an exact non-negative integer (SPEC §10.5).
  defp ceil_packages(%D{coef: 0}, _size), do: 0

  defp ceil_packages(%D{coef: q_coef, exp: q_exp}, %D{coef: s_coef, exp: s_exp}) do
    {numerator, denominator} =
      if q_exp - s_exp >= 0 do
        {q_coef * Integer.pow(10, q_exp - s_exp), s_coef}
      else
        {q_coef, s_coef * Integer.pow(10, s_exp - q_exp)}
      end

    div(numerator + denominator - 1, denominator)
  end

  ## Shared helpers

  defp flat_fee_major(0, _currency), do: D.new(0)

  defp flat_fee_major(fee_minor, currency) when is_integer(fee_minor) do
    Money.to_major_decimal(Money.new!(currency, fee_minor))
  end

  defp require_non_negative_quantity(%D{} = quantity, model_type) do
    if D.compare(quantity, D.new(0)) == :lt do
      {:error, {:negative_quantity, model_type}}
    else
      :ok
    end
  end

  defp require_positive(%D{} = value, error) do
    if D.compare(value, D.new(0)) == :gt, do: :ok, else: {:error, error}
  end

  # The single rounding boundary per line (SPEC §9.3) plus the shared trace
  # keys (INV-012). Traces are canonical-JSON-safe: string keys, strings,
  # integers, booleans, and nil only.
  defp finalize(unrounded, %RatingRequest{currency: currency} = request, model_type, extra) do
    amount = Money.round_major(unrounded, currency)
    delta = Money.rounding_delta_minor(unrounded, currency)

    trace =
      %{
        "schema_version" => Schema.schema_version(),
        "model" => model_type,
        "currency" => currency,
        "quantity" => Schema.decimal_string(request.quantity),
        "unrounded_amount" => Schema.decimal_string(unrounded),
        "rounding_delta_minor" => Schema.decimal_string(delta),
        "amount_minor" => amount.minor_units
      }
      |> Map.merge(period_trace(request))
      |> Map.merge(extra)

    {:ok, %ChargeResult{amount: amount, unrounded: unrounded, trace: trace}}
  end

  defp period_trace(%RatingRequest{full_period: nil}), do: %{}

  defp period_trace(%RatingRequest{full_period: full, active_period: active}) do
    active = active || full

    %{
      "full_period" => period_map(full),
      "active_period" => period_map(active),
      "period_days" => Period.days(full),
      "active_days" => Period.days(active)
    }
  end

  defp period_map(%Period{} = period) do
    %{
      "start" => Date.to_iso8601(period.start_date),
      "end_exclusive" => Date.to_iso8601(period.end_date_exclusive)
    }
  end
end
