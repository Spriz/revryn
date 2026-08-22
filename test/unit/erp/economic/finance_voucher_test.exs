defmodule BillingCore.ERP.Economic.FinanceVoucherTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.Economic
  alias BillingCore.ERP.Vouchers.{FinanceVoucher, FinanceVoucherLine, Voucher}

  @stub __MODULE__.Stub
  @reference "ABC:CREDIT-CLOSE:close-1:2026-08:DKK"

  defp context do
    %{
      connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
      team_id: "b7f3f0a4-0000-0000-0000-000000000002",
      provider: :economic,
      journal_external_id: "7",
      accounting_year_external_id: "2026",
      credentials: %{app_secret_token: "app-secret-token", agreement_grant_token: "grant-token"},
      plug: {Req.Test, @stub}
    }
  end

  defp voucher do
    %FinanceVoucher{
      external_reference: @reference,
      accounting_date: ~D[2026-08-31],
      accounting_year_external_id: "2026",
      journal_external_id: "7",
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
  end

  test "posts aggregate finance entries with exact Decimal JSON amounts" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:voucher_request, conn, body})

      Plug.Conn.send_resp(
        conn,
        201,
        ~s({"voucherNumber":3,"date":"2026-08-31","currency":{"code":"DKK"},"text":"ABC:CREDIT-CLOSE:close-1:2026-08:DKK","accountingYear":{"year":2026},"journal":{"journalNumber":7},"entries":{"financeVouchers":[{"account":{"accountNumber":2990},"amount":-125.00,"date":"2026-08-31","text":"ABC:CREDIT-CLOSE:close-1:2026-08:DKK"},{"account":{"accountNumber":5890},"amount":125.00,"date":"2026-08-31","text":"ABC:CREDIT-CLOSE:close-1:2026-08:DKK"}]}})
      )
    end)

    assert {:ok, %Voucher{external_voucher_number: "3"}} =
             Economic.create_finance_voucher(context(), voucher(), "credit-close:create:1")

    assert_received {:voucher_request, conn, body}
    assert conn.method == "POST"
    assert conn.request_path == "/journals/7/vouchers"
    assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["credit-close:create:1"]

    assert Jason.decode!(body, floats: :decimals) == %{
             "accountingYear" => %{"year" => 2026},
             "entries" => %{
               "financeVouchers" => [
                 %{
                   "account" => %{"accountNumber" => 2990},
                   "amount" => Decimal.new("-125.00"),
                   "currency" => %{"code" => "DKK"},
                   "date" => "2026-08-31",
                   # The sole liability line is the exact recovery key so an
                   # equality-filter lookup can find an unknown write.
                   "text" => @reference
                 },
                 %{
                   "account" => %{"accountNumber" => 5890},
                   "amount" => Decimal.new("125.00"),
                   "currency" => %{"code" => "DKK"},
                   "date" => "2026-08-31",
                   "text" => @reference <> " | Aggregate close offset"
                 }
               ]
             }
           }
  end

  test "a transport loss while uploading a PDF report remains an unknown outcome" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/journals/7/vouchers/2026-3"} ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s({"voucherNumber":3,"date":"2026-08-31","currency":{"code":"DKK"},"text":"ABC:CREDIT-CLOSE:close-1:2026-08:DKK","accountingYear":{"year":2026},"journal":{"journalNumber":7},"entries":{"financeVouchers":[]}})
          )

        {"POST", "/journals/7/vouchers/2026-3/attachment/file"} ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    content = "pdf"

    report = %BillingCore.ERP.Vouchers.AttachmentEvidence{
      filename: "report.pdf",
      content_type: "application/pdf",
      content: content,
      byte_size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }

    assert {:unknown, hint} =
             Economic.attach_voucher_report(
               context(),
               {:voucher, "3"},
               report,
               "credit-close:report:1"
             )

    assert {:voucher, "3"} in hint.search_by
  end
end
