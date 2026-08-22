defmodule BillingCore.ERP.Vouchers.FinanceVoucher do
  @moduledoc """
  Adapter-neutral aggregate finance voucher (SPEC §16.1 and §17.16).

  `external_reference` is the stable close reference. Amounts are signed
  integer minor units in `Money`, with debit-positive signs. No provider field
  names or customer-level dimensions may cross this boundary.
  """

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.Vouchers.FinanceVoucherLine

  @enforce_keys [
    :external_reference,
    :accounting_date,
    :accounting_year_external_id,
    :journal_external_id,
    :currency,
    :lines
  ]
  defstruct [
    :external_reference,
    :accounting_date,
    :accounting_year_external_id,
    :journal_external_id,
    :currency,
    :lines,
    vat_neutral: true
  ]

  @type t :: %__MODULE__{
          external_reference: String.t(),
          accounting_date: Date.t(),
          accounting_year_external_id: String.t(),
          journal_external_id: String.t(),
          currency: String.t(),
          lines: [FinanceVoucherLine.t()],
          vat_neutral: true
        }

  @doc "Validates the aggregate, balanced close-voucher invariant."
  @spec validate(t()) :: :ok | {:error, [map()]}
  def validate(%__MODULE__{} = voucher) do
    errors =
      []
      |> validate_required(voucher)
      |> validate_lines(voucher)
      |> validate_balance(voucher)

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  defp validate_required(errors, voucher) do
    required = [
      external_reference: voucher.external_reference,
      accounting_date: voucher.accounting_date,
      accounting_year_external_id: voucher.accounting_year_external_id,
      journal_external_id: voucher.journal_external_id,
      currency: voucher.currency
    ]

    Enum.reduce(required, errors, fn {field, value}, acc ->
      if present?(value), do: acc, else: [%{field: field, code: :required} | acc]
    end)
  end

  defp validate_lines(errors, %__MODULE__{lines: lines, currency: currency})
       when is_list(lines) do
    errors = validate_shape(errors, lines)

    Enum.reduce(lines, errors, fn
      %FinanceVoucherLine{} = line, acc -> validate_line(acc, line, currency)
      _other, acc -> [%{field: :lines, code: :invalid_line} | acc]
    end)
  end

  defp validate_lines(errors, _voucher), do: [%{field: :lines, code: :invalid_lines} | errors]

  # Two document shapes share the canonical voucher: the aggregate liability
  # close (exactly one liability line plus balancing lines) and the
  # receivable settlement (SPEC §9.4.1 — exactly one clearing and one contra
  # line, never mixed with close lines).
  defp validate_shape(errors, lines) do
    role_count = fn role ->
      Enum.count(lines, &(match?(%FinanceVoucherLine{}, &1) and &1.role == role))
    end

    settlement_lines = role_count.(:settlement_clearing) + role_count.(:settlement_contra)

    cond do
      settlement_lines == 0 ->
        if role_count.(:customer_credit_liability) == 1 do
          errors
        else
          [%{field: :lines, code: :exactly_one_liability_line} | errors]
        end

      role_count.(:settlement_clearing) == 1 and role_count.(:settlement_contra) == 1 and
          length(lines) == 2 ->
        errors

      true ->
        [%{field: :lines, code: :invalid_settlement_shape} | errors]
    end
  end

  defp validate_line(errors, line, currency) do
    errors
    |> require_line_value(line.line_key, :line_key)
    |> require_line_value(line.account_external_id, :account_external_id)
    |> validate_role(line.role)
    |> validate_amount(line.amount, currency)
  end

  defp require_line_value(errors, value, field) do
    if present?(value), do: errors, else: [%{field: field, code: :required} | errors]
  end

  defp validate_role(errors, role)
       when role in [
              :customer_credit_liability,
              :balancing,
              :settlement_clearing,
              :settlement_contra
            ],
       do: errors

  defp validate_role(errors, _role), do: [%{field: :role, code: :invalid_role} | errors]

  defp validate_amount(errors, %Money{currency: currency}, currency), do: errors

  defp validate_amount(errors, %Money{}, _currency),
    do: [%{field: :amount, code: :currency_mismatch} | errors]

  defp validate_amount(errors, _amount, _currency),
    do: [%{field: :amount, code: :invalid_amount} | errors]

  defp validate_balance(errors, %__MODULE__{lines: lines, currency: currency})
       when is_list(lines) do
    amounts = for %FinanceVoucherLine{amount: %Money{} = amount} <- lines, do: amount

    if length(amounts) == length(lines) and Money.sum!(amounts, currency).minor_units != 0 do
      [%{field: :lines, code: :unbalanced} | errors]
    else
      errors
    end
  end

  defp validate_balance(errors, _voucher), do: errors

  defp present?(%Date{}), do: true
  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false
end
