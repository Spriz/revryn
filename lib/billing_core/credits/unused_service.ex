defmodule BillingCore.Credits.UnusedService do
  @moduledoc """
  Deterministic unused-prepaid-service credit for a downgrade or
  cancellation (BC-US-107, BC-TASK-102).

  Given a booked over-time invoice line, a change effective date, and the
  quantity reduction, the unused value is exactly

      line_amount × (unused_days / period_days) × (Δquantity / quantity)

  computed in `Decimal` and rounded half-away-from-zero once at the final
  amount (INV-011/012) via the shared money kernel — never floating point.
  The credit note is created through the ordinary correction workflow, and
  once it is authoritative (booked) its eligible net value funds the
  customer-credit ledger exactly once under a case-derived idempotency key.
  The original booked invoice is never mutated.
  """

  alias BillingCore.{Credits, Repo, Scope}
  alias BillingCore.Billing.{Corrections, InvoiceIntent, InvoiceLine}
  alias BillingCore.Domain.{Money, Period}

  import Ecto.Query

  @doc """
  Pure computation for one over-time line. Attrs: `:effective_date` (the
  reduction date), `:original_quantity`, `:reduced_quantity`. Returns the
  credit in minor units plus the exact fractions used, or an error when
  the reduction or date is not creditable.
  """
  @spec compute(InvoiceLine.t(), map()) ::
          {:ok,
           %{
             credit_minor: pos_integer(),
             unused_days: pos_integer(),
             period_days: pos_integer(),
             quantity_delta: Decimal.t()
           }}
          | {:error, term()}
  def compute(%InvoiceLine{} = line, attrs) do
    attrs = Map.new(attrs)

    with :ok <- ensure_over_time(line),
         {:ok, effective} <- fetch_date(attrs, :effective_date),
         {:ok, original_quantity} <- fetch_positive_decimal(attrs, :original_quantity),
         {:ok, reduced_quantity} <- fetch_reduced(attrs, original_quantity),
         :ok <- ensure_within_period(line, effective) do
      full_period = Period.new!(line.service_start, line.service_end_exclusive)
      unused_period = Period.new!(effective, line.service_end_exclusive)
      period_days = Date.diff(line.service_end_exclusive, line.service_start)
      unused_days = Date.diff(line.service_end_exclusive, effective)
      quantity_delta = Decimal.sub(original_quantity, reduced_quantity)

      # The same §10.1 day-based proration rule the rating engine applies.
      fraction =
        full_period
        |> Period.proration_fraction(unused_period)
        |> Decimal.mult(Decimal.div(quantity_delta, original_quantity))

      major =
        line.amount_minor
        |> Decimal.new()
        |> Decimal.div(pow10(Money.exponent(line.currency)))
        |> Decimal.mult(fraction)

      credit_minor = Money.round_major(major, line.currency).minor_units

      if credit_minor > 0 do
        {:ok,
         %{
           credit_minor: credit_minor,
           unused_days: unused_days,
           period_days: period_days,
           quantity_delta: quantity_delta
         }}
      else
        {:error, :nothing_to_credit}
      end
    end
  end

  @doc """
  Creates the correction credit note for a quantity reduction on a booked
  invoice. Attrs: `:line_key`, `:effective_date`, `:original_quantity`,
  `:reduced_quantity`, optional `:narrative`. Returns the correction case,
  the frozen credit-note intent, and the computation evidence. Funding
  happens separately, once the credit note is authoritative
  (`fund_from_case/2`, invoked automatically on case completion).
  """
  @spec credit_reduction(Scope.t(), InvoiceIntent.t(), map()) ::
          {:ok, %{case: struct(), credit_intent: InvoiceIntent.t(), computation: map()}}
          | {:error, term()}
  def credit_reduction(%Scope{} = scope, %InvoiceIntent{} = intent, attrs) do
    attrs = Map.new(attrs)

    with {:ok, line} <- fetch_line(intent, attrs[:line_key]),
         {:ok, computation} <- compute(line, attrs) do
      narrative =
        attrs[:narrative] ||
          "Unused prepaid service: quantity #{attrs[:original_quantity]} → " <>
            "#{attrs[:reduced_quantity]} effective #{attrs[:effective_date]} " <>
            "(#{computation.unused_days}/#{computation.period_days} days unused)"

      case Corrections.create_partial_credit(
             scope,
             intent,
             [{line.line_key, computation.credit_minor}],
             reason_code: "unused_prepaid_service",
             narrative: narrative
           ) do
        {:ok, result} -> {:ok, Map.put(result, :computation, computation)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Funds the customer-credit ledger from an authoritative
  `unused_prepaid_service` correction case, exactly once (the idempotency
  key derives from the case). Requires a credit account for the customer
  in the credit note's currency; called automatically when such a case
  completes.
  """
  @spec fund_from_case(Scope.t(), struct()) :: {:ok, struct()} | {:error, term()}
  def fund_from_case(%Scope{} = scope, correction_case) do
    credit_intent = Repo.get!(InvoiceIntent, correction_case.credit_invoice_intent_id)
    amount_minor = abs(credit_intent.net_amount_minor)

    credited_line_id =
      Repo.one(
        from line in InvoiceLine,
          where: line.invoice_intent_id == ^correction_case.original_invoice_intent_id,
          order_by: [asc: line.ordinal],
          limit: 1,
          select: line.id
      )

    with {:ok, account} <- credit_account_for(scope, credit_intent) do
      Credits.grant_credit(scope, %{
        credit_account_id: account.id,
        origin_type: "unused_prepaid_service",
        origin_id: correction_case.id,
        origin_invoice_line_id: credited_line_id,
        amount_minor: amount_minor,
        currency: credit_intent.currency,
        idempotency_key: "unused-service:#{correction_case.id}",
        reason_code: correction_case.reason_code
      })
    end
  end

  defp credit_account_for(scope, credit_intent) do
    with {:ok, accounts} <- Credits.list_accounts_for_customer(scope, credit_intent.customer_id),
         %{} = account <- Enum.find(accounts, &(&1.currency == credit_intent.currency)) do
      {:ok, account}
    else
      nil -> {:error, :no_credit_account}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_line(intent, line_key) when is_binary(line_key) do
    case Repo.one(
           from line in InvoiceLine,
             where: line.invoice_intent_id == ^intent.id and line.line_key == ^line_key
         ) do
      nil -> {:error, :line_not_found}
      line -> {:ok, line}
    end
  end

  defp fetch_line(_intent, _line_key), do: {:error, :line_not_found}

  defp ensure_over_time(%InvoiceLine{recognition_mode: "over_time"} = line)
       when not is_nil(line.service_start) and not is_nil(line.service_end_exclusive),
       do: :ok

  defp ensure_over_time(_line), do: {:error, :not_an_over_time_line}

  defp ensure_within_period(line, %Date{} = effective) do
    if not Date.before?(effective, line.service_start) and
         Date.before?(effective, line.service_end_exclusive),
       do: :ok,
       else: {:error, :effective_date_outside_service_period}
  end

  defp fetch_date(attrs, key) do
    case attrs[key] do
      %Date{} = date -> {:ok, date}
      _other -> {:error, {:invalid_attribute, key}}
    end
  end

  defp fetch_positive_decimal(attrs, key) do
    with %Decimal{} = value <- to_decimal(attrs[key]),
         :gt <- Decimal.compare(value, 0) do
      {:ok, value}
    else
      _ -> {:error, {:invalid_attribute, key}}
    end
  end

  defp fetch_reduced(attrs, original_quantity) do
    with %Decimal{} = reduced <- to_decimal(attrs[:reduced_quantity]),
         :lt <- Decimal.compare(reduced, original_quantity),
         comparison when comparison in [:gt, :eq] <- Decimal.compare(reduced, 0) do
      {:ok, reduced}
    else
      _ -> {:error, :not_a_reduction}
    end
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(_other), do: nil

  defp pow10(exponent), do: Decimal.new(Integer.pow(10, exponent))
end
