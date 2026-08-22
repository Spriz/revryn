defmodule BillingCore.ERP.Vouchers.FinanceVoucherValidationTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.Vouchers.{FinanceVoucher, FinanceVoucherLine}

  defp line(overrides) do
    base = %FinanceVoucherLine{
      line_key: "liability",
      account_external_id: "2990",
      amount: Money.new!("DKK", -12_500),
      role: :customer_credit_liability
    }

    struct!(base, overrides)
  end

  defp voucher(overrides \\ []) do
    base = %FinanceVoucher{
      external_reference: "ABC:CREDIT-CLOSE:close-1:2026-08:DKK",
      accounting_date: ~D[2026-08-31],
      accounting_year_external_id: "2026",
      journal_external_id: "7",
      currency: "DKK",
      lines: [
        line([]),
        line(
          line_key: "offset",
          account_external_id: "5890",
          amount: Money.new!("DKK", 12_500),
          role: :balancing
        )
      ]
    }

    struct!(base, overrides)
  end

  defp settlement_lines do
    [
      line(
        line_key: "clearing",
        account_external_id: "5600",
        amount: Money.new!("DKK", -40_000),
        role: :settlement_clearing
      ),
      line(
        line_key: "contra",
        account_external_id: "2990",
        amount: Money.new!("DKK", 40_000),
        role: :settlement_contra
      )
    ]
  end

  test "the aggregate close shape and the settlement shape both validate" do
    assert FinanceVoucher.validate(voucher()) == :ok
    assert FinanceVoucher.validate(voucher(lines: settlement_lines())) == :ok
  end

  test "settlement lines mixed with close lines are an invalid shape (SPEC §9.4.1)" do
    mixed = voucher(lines: [line([]) | settlement_lines()])

    assert {:error, errors} = FinanceVoucher.validate(mixed)
    assert Enum.any?(errors, &(&1.code == :invalid_settlement_shape))
  end

  test "a settlement needs exactly one clearing and one contra line" do
    [clearing, _contra] = settlement_lines()

    two_clearings =
      voucher(
        lines: [
          clearing,
          line(
            line_key: "clearing-2",
            account_external_id: "5601",
            amount: Money.new!("DKK", 40_000),
            role: :settlement_clearing
          )
        ]
      )

    assert {:error, errors} = FinanceVoucher.validate(two_clearings)
    assert Enum.any?(errors, &(&1.code == :invalid_settlement_shape))
  end

  test "a non-line entry in lines is reported as invalid_line" do
    assert {:error, errors} =
             FinanceVoucher.validate(voucher(lines: [line([]), %{"account" => "5890"}]))

    assert Enum.any?(errors, &(&1.code == :invalid_line))
  end

  test "lines that are not a list at all are invalid_lines and skip the balance check" do
    assert {:error, errors} = FinanceVoucher.validate(voucher(lines: nil))
    assert Enum.any?(errors, &(&1.code == :invalid_lines))
    refute Enum.any?(errors, &(&1.code == :unbalanced))
  end

  test "an unknown line role is rejected" do
    bogus_role =
      voucher(
        lines: [line([]), line(line_key: "x", role: :refund, amount: Money.new!("DKK", 12_500))]
      )

    assert {:error, errors} = FinanceVoucher.validate(bogus_role)
    assert Enum.any?(errors, &(&1.code == :invalid_role))
  end

  test "a line in another currency is a currency mismatch" do
    mixed =
      voucher(
        lines: [
          line(amount: Money.new!("EUR", -12_500)),
          line(line_key: "offset", account_external_id: "5890", amount: 12_500, role: :balancing)
        ]
      )

    assert {:error, errors} = FinanceVoucher.validate(mixed)
    assert Enum.any?(errors, &(&1.code == :currency_mismatch))
    assert Enum.any?(errors, &(&1.code == :invalid_amount))
  end

  test "mixed-currency Money lines report currency_mismatch instead of raising" do
    # Regression: the balance check once summed ALL Money lines with
    # Money.sum!/2, which raised on a foreign-currency line before the
    # error list could be returned.
    mixed_money =
      voucher(
        lines: [
          line(amount: Money.new!("EUR", -12_500)),
          line(
            line_key: "offset",
            account_external_id: "5890",
            amount: Money.new!("DKK", 12_500),
            role: :balancing
          )
        ]
      )

    assert {:error, errors} = FinanceVoucher.validate(mixed_money)
    assert Enum.any?(errors, &(&1.code == :currency_mismatch))
    refute Enum.any?(errors, &(&1.code == :invalid_amount))
  end

  test "a non-Money amount is invalid and never counted toward the balance" do
    no_money =
      voucher(
        lines: [
          line([]),
          line(line_key: "offset", account_external_id: "5890", amount: 125.0, role: :balancing)
        ]
      )

    assert {:error, errors} = FinanceVoucher.validate(no_money)
    assert Enum.any?(errors, &(&1.code == :invalid_amount))
    refute Enum.any?(errors, &(&1.code == :unbalanced))
  end

  test "blank line keys and accounts are required" do
    blank =
      voucher(
        lines: [
          line(line_key: ""),
          line(
            line_key: "offset",
            account_external_id: nil,
            amount: Money.new!("DKK", 12_500),
            role: :balancing
          )
        ]
      )

    assert {:error, errors} = FinanceVoucher.validate(blank)
    assert %{field: :line_key, code: :required} in errors
    assert %{field: :account_external_id, code: :required} in errors
  end

  test "non-date, non-string header values are simply not present" do
    assert {:error, errors} = FinanceVoucher.validate(voucher(accounting_date: nil))
    assert %{field: :accounting_date, code: :required} in errors

    assert {:error, errors} = FinanceVoucher.validate(voucher(journal_external_id: 7))
    assert %{field: :journal_external_id, code: :required} in errors
  end
end
