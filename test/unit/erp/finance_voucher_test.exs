defmodule BillingCore.ERP.FinanceVoucherTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.FakeERP
  alias BillingCore.ERP.Vouchers.{AttachmentEvidence, FinanceVoucher, FinanceVoucherLine, Voucher}

  setup do
    server = start_supervised!(FakeERP)
    %{server: server, ctx: FakeERP.connection_context(server)}
  end

  defp voucher(overrides \\ []) do
    base = %FinanceVoucher{
      external_reference: "ABC:CREDIT-CLOSE:close-1:2026-08:DKK",
      accounting_date: ~D[2026-08-31],
      accounting_year_external_id: "2026",
      journal_external_id: "1",
      currency: "DKK",
      lines: [
        %FinanceVoucherLine{
          line_key: "liability",
          account_external_id: "2990",
          amount: Money.new!("DKK", -12_500),
          role: :customer_credit_liability,
          description: "Customer-credit liability close"
        },
        %FinanceVoucherLine{
          line_key: "offset",
          account_external_id: "5890",
          amount: Money.new!("DKK", 12_500),
          role: :balancing,
          description: "Aggregate close offset"
        }
      ]
    }

    struct!(base, overrides)
  end

  defp report do
    content = "credit-close-report"

    %AttachmentEvidence{
      filename: "credit-close.pdf",
      content_type: "application/pdf",
      content: content,
      byte_size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }
  end

  test "requires one aggregate liability line and balanced signed amounts" do
    assert {:error, errors} = FinanceVoucher.validate(voucher(lines: []))
    assert Enum.any?(errors, &(&1.code == :exactly_one_liability_line))

    unbalanced = voucher(lines: [hd(voucher().lines)])
    assert {:error, errors} = FinanceVoucher.validate(unbalanced)
    assert Enum.any?(errors, &(&1.code == :unbalanced))
  end

  test "creates, reads and idempotently recovers exactly one voucher", %{server: server, ctx: ctx} do
    expected = voucher()

    assert {:ok, %Voucher{} = created} =
             FakeERP.create_finance_voucher(ctx, expected, "credit-close:create:1")

    assert {:ok, ^created} =
             FakeERP.create_finance_voucher(ctx, expected, "credit-close:create:1")

    assert [^created] = FakeERP.list_finance_vouchers(server)
    assert {:ok, ^created} = FakeERP.get_finance_voucher(ctx, {:voucher, "1"})
    assert {:ok, ^created} = FakeERP.find_finance_voucher(ctx, expected.external_reference)
  end

  test "lost voucher response commits once and is recoverable by stable reference", %{
    server: server,
    ctx: ctx
  } do
    :ok = FakeERP.inject_unknown_outcome(server, :create_finance_voucher)

    assert {:unknown, %{search_by: [{:external_reference, reference}]}} =
             FakeERP.create_finance_voucher(ctx, voucher(), "credit-close:create:unknown")

    assert reference == voucher().external_reference

    assert {:ok, %Voucher{external_voucher_number: "1"}} =
             FakeERP.find_finance_voucher(ctx, reference)

    assert [_one] = FakeERP.list_finance_vouchers(server)
  end

  test "attachment is persisted as hash evidence and response loss remains recoverable", %{
    server: server,
    ctx: ctx
  } do
    assert {:ok, voucher} =
             FakeERP.create_finance_voucher(ctx, voucher(), "credit-close:create:2")

    :ok = FakeERP.inject_unknown_outcome(server, :attach_voucher_report)

    assert {:unknown, _hint} =
             FakeERP.attach_voucher_report(
               ctx,
               {:voucher, voucher.external_voucher_number},
               report(),
               "report:2"
             )

    assert {:ok, %AttachmentEvidence{content: nil, external_attachment_id: "attachment-1"}} =
             FakeERP.get_voucher_attachment(ctx, {:voucher, voucher.external_voucher_number})

    assert :ok =
             FakeERP.attach_voucher_report(
               ctx,
               {:voucher, voucher.external_voucher_number},
               report(),
               "report:2"
             )
  end
end
