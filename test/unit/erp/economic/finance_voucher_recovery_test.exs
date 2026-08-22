defmodule BillingCore.ERP.Economic.FinanceVoucherRecoveryTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.Economic
  alias BillingCore.ERP.Vouchers.{AttachmentEvidence, FinanceVoucher, FinanceVoucherLine, Voucher}

  @stub __MODULE__.Stub
  @reference "ABC:CREDIT-CLOSE:close-1:2026-08:DKK"

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
        team_id: "b7f3f0a4-0000-0000-0000-000000000002",
        provider: :economic,
        journal_external_id: "7",
        accounting_year_external_id: "2026",
        credentials: %{app_secret_token: "app-secret", agreement_grant_token: "grant"},
        plug: {Req.Test, @stub}
      },
      extra
    )
  end

  # A connection context that configures the credit-close voucher targets via
  # :mappings instead of top-level keys (the fallback lookups).
  defp mappings_context do
    %{
      connection_id: "b7f3f0a4-0000-0000-0000-000000000001",
      team_id: "b7f3f0a4-0000-0000-0000-000000000002",
      provider: :economic,
      currency: "DKK",
      accounting_date: ~D[2026-08-31],
      credit_liability_account_external_id: "2990",
      mappings: %{
        credit_close_journal_external_id: "9",
        credit_close_accounting_year_external_id: "2027"
      },
      credentials: %{app_secret_token: "app-secret", agreement_grant_token: "grant"},
      plug: {Req.Test, @stub}
    }
  end

  defp voucher(overrides \\ []) do
    base = %FinanceVoucher{
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

    struct!(base, overrides)
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  @voucher_payload ~s({"voucherNumber":3,"date":"2026-08-31","currency":{"code":"DKK"},) <>
                     ~s("text":"#{@reference}","accountingYear":{"year":2026},) <>
                     ~s("journal":{"journalNumber":7},"entries":{"financeVouchers":[]}})

  # -- find_finance_voucher ---------------------------------------------------

  test "recovers a voucher by reference via mapping-configured journal, with line roles" do
    Req.Test.stub(@stub, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:search, conn.request_path, conn.query_params["filter"]})

      json_resp(
        conn,
        200,
        ~s({"collection": [{"voucherNumber": 12, "date": "2026-08-31", "currency": "DKK",) <>
          ~s( "entries": {"financeVouchers": [) <>
          ~s({"account": {"accountNumber": 2990}, "amount": -125, "text": "#{@reference}"},) <>
          ~s({"accountNumber": 5890, "amount": "125.00", "text": "#{@reference} | offset"}) <>
          ~s(]}}]})
      )
    end)

    assert {:ok, %Voucher{} = found} =
             Economic.find_finance_voucher(mappings_context(), @reference)

    assert_received {:search, "/journals/9/vouchers", "text$eq:" <> @reference}

    assert found.external_voucher_number == "12"
    assert found.external_reference == @reference
    # Journal/year come from the mapping fallbacks when the payload omits them.
    assert found.journal_external_id == "9"
    assert found.accounting_year_external_id == "2027"
    # Bare-string currency payloads normalize the same as {"code": ...}.
    assert found.currency == "DKK"

    # Integer and string amounts both convert exactly; the configured
    # liability account keeps its role, everything else balances.
    assert [liability, balancing] = found.lines
    assert liability.account_external_id == "2990"
    assert liability.amount == Money.new!("DKK", -12_500)
    assert liability.role == :customer_credit_liability
    assert balancing.account_external_id == "5890"
    assert balancing.amount == Money.new!("DKK", 12_500)
    assert balancing.role == :balancing
  end

  test "find returns nil when no voucher matches the reference" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 200, ~s({"collection": []})) end)

    assert {:ok, nil} = Economic.find_finance_voucher(context(), @reference)
  end

  test "a search hit without a voucher number is a provider failure" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 200, ~s({"collection": [{"note": "corrupt"}]}))
    end)

    assert {:error, {:provider_failure, detail}} =
             Economic.find_finance_voucher(context(), @reference)

    assert detail =~ "lacked required fields"
  end

  test "voucher search failures classify; transport losses are provider failures" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 500, ~s({"message": "boom"})) end)

    assert {:error, {:provider_failure, 500}} =
             Economic.find_finance_voucher(context(), @reference)

    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:provider_failure, :timeout}} =
             Economic.find_finance_voucher(context(), @reference)
  end

  test "get_finance_voucher by external reference delegates to the search" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 200, ~s({"collection": []})) end)

    assert {:ok, nil} =
             Economic.get_finance_voucher(context(), {:external_reference, @reference})
  end

  # -- get_finance_voucher by number ------------------------------------------

  test "a missing voucher number reads as nil" do
    Req.Test.stub(@stub, fn conn ->
      assert conn.request_path == "/journals/7/vouchers/2026-3"
      json_resp(conn, 404, ~s({"message": "no voucher"}))
    end)

    assert {:ok, nil} = Economic.get_finance_voucher(context(), {:voucher, "3"})
  end

  test "a voucher read without required fields is a provider failure" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 200, ~s({"noNumber": true})) end)

    assert {:error, {:provider_failure, detail}} =
             Economic.get_finance_voucher(context(), {:voucher, "3"})

    assert detail =~ "voucher read lacked required fields"
  end

  # Note: the voucher_date/2 fallback error branch (payload date unparsable
  # AND no %Date{} default) is not exercised: create-path defaults come from a
  # voucher that already passed FinanceVoucher.validate/1 (Date required), and
  # read-path defaults always fall back to Date.utc_today/0 unless a context
  # explicitly carries a non-Date :accounting_date. It is defensive only.
  test "a minimal voucher read falls back to context defaults for currency and date" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 200, ~s({"voucherNumber": 3})) end)

    assert {:ok, %Voucher{} = read} =
             Economic.get_finance_voucher(
               context(%{accounting_date: ~D[2026-08-31]}),
               {:voucher, "3"}
             )

    assert read.external_voucher_number == "3"
    assert read.currency == "DKK"
    assert read.accounting_date == ~D[2026-08-31]
    assert read.lines == []
  end

  test "voucher reads classify errors and treat transport losses as provider failures" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 500, ~s({"message": "boom"})) end)

    assert {:error, {:provider_failure, 500}} =
             Economic.get_finance_voucher(context(), {:voucher, "3"})

    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, {:provider_failure, :timeout}} =
             Economic.get_finance_voucher(context(), {:voucher, "3"})
  end

  # -- create_finance_voucher outcomes ----------------------------------------

  test "a 2xx create without a voucher number is an unknown outcome" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 201, ~s({})) end)

    assert {:unknown, hint} =
             Economic.create_finance_voucher(context(), voucher(), "credit-close:create:1")

    assert hint.search_by == [{:external_reference, @reference}]
    assert hint.detail =~ "lacked a voucher number"
  end

  test "a create response with unusable entries is an unknown outcome" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(
        conn,
        201,
        ~s({"voucherNumber": 3, "date": "2026-08-31",) <>
          ~s( "entries": {"financeVouchers": "corrupt"}})
      )
    end)

    assert {:unknown, _hint} =
             Economic.create_finance_voucher(context(), voucher(), "credit-close:create:1")
  end

  test "a response line without a usable amount is an unknown outcome" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(
        conn,
        201,
        ~s({"voucherNumber": 3, "date": "2026-08-31", "entries": {"financeVouchers":) <>
          ~s( [{"account": {"accountNumber": 2990}, "amount": true}]}})
      )
    end)

    assert {:unknown, _hint} =
             Economic.create_finance_voucher(context(), voucher(), "credit-close:create:1")
  end

  test "a create rejection classifies as validation" do
    Req.Test.stub(@stub, fn conn ->
      json_resp(conn, 422, ~s({"message": "Journal closed"}))
    end)

    assert {:error, {:validation, [%{message: "Journal closed"}]}} =
             Economic.create_finance_voucher(context(), voucher(), "credit-close:create:1")
  end

  test "a transport loss during create is an unknown outcome" do
    Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:unknown, hint} =
             Economic.create_finance_voucher(context(), voucher(), "credit-close:create:1")

    assert hint.search_by == [{:external_reference, @reference}]
  end

  test "a balancing line without a description carries the bare recovery reference" do
    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:create_body, Jason.decode!(body, floats: :decimals)})
      json_resp(conn, 201, @voucher_payload)
    end)

    no_description =
      voucher(
        lines: [
          hd(voucher().lines),
          %FinanceVoucherLine{
            line_key: "offset",
            account_external_id: "5890",
            amount: Money.new!("DKK", 12_500),
            role: :balancing
          }
        ]
      )

    assert {:ok, %Voucher{}} =
             Economic.create_finance_voucher(context(), no_description, "credit-close:create:1")

    assert_received {:create_body, body}
    entries = get_in(body, ["entries", "financeVouchers"])
    assert Enum.map(entries, & &1["text"]) == [@reference, @reference]
  end

  # -- attachments -------------------------------------------------------------

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

  test "attaching a report resolves the voucher and posts the file with the operation key" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/journals/7/vouchers/2026-3"} ->
          json_resp(conn, 200, @voucher_payload)

        {"POST", "/journals/7/vouchers/2026-3/attachment/file"} ->
          send(self(), {:upload, conn})
          json_resp(conn, 200, ~s({}))
      end
    end)

    assert :ok =
             Economic.attach_voucher_report(context(), {:voucher, "3"}, report(), "report:1")

    assert_received {:upload, conn}
    assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["report:1"]
  end

  test "attaching to a voucher that does not exist is not_found" do
    Req.Test.stub(@stub, fn conn -> json_resp(conn, 404, ~s({"message": "gone"})) end)

    assert {:error, {:not_found, {:voucher, "3"}}} =
             Economic.attach_voucher_report(context(), {:voucher, "3"}, report(), "report:1")
  end

  test "an upload rejection classifies" do
    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/journals/7/vouchers/2026-3"} ->
          json_resp(conn, 200, @voucher_payload)

        {"POST", "/journals/7/vouchers/2026-3/attachment/file"} ->
          json_resp(conn, 500, ~s({"message": "boom"}))
      end
    end)

    assert {:error, {:provider_failure, 500}} =
             Economic.attach_voucher_report(context(), {:voucher, "3"}, report(), "report:1")
  end

  test "evidence without content is rejected before any provider call" do
    metadata_only = %AttachmentEvidence{report() | content: nil}

    assert {:error, [%{field: :content, code: :required}]} =
             Economic.attach_voucher_report(context(), {:voucher, "3"}, metadata_only, "r:1")
  end

  test "get_voucher_attachment returns nil when no attachment exists" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" -> json_resp(conn, 200, @voucher_payload)
        "/journals/7/vouchers/2026-3/attachment" -> json_resp(conn, 404, ~s({}))
      end
    end)

    assert {:ok, nil} = Economic.get_voucher_attachment(context(), {:voucher, "3"})
  end

  test "get_voucher_attachment reads metadata plus file into hash evidence" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" ->
          json_resp(conn, 200, @voucher_payload)

        "/journals/7/vouchers/2026-3/attachment" ->
          json_resp(conn, 200, ~s({"fileName": "evidence.pdf", "attachmentNumber": 5}))

        "/journals/7/vouchers/2026-3/attachment/file" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/pdf")
          |> Plug.Conn.send_resp(200, "PDFDATA")
      end
    end)

    assert {:ok, %AttachmentEvidence{} = evidence} =
             Economic.get_voucher_attachment(context(), {:voucher, "3"})

    assert evidence.filename == "evidence.pdf"
    assert evidence.content_type == "application/pdf"
    assert evidence.byte_size == byte_size("PDFDATA")
    assert evidence.sha256 == :crypto.hash(:sha256, "PDFDATA") |> Base.encode16(case: :lower)
    assert evidence.external_attachment_id == "5"
  end

  test "attachment metadata fallbacks apply when the provider omits fields" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" ->
          json_resp(conn, 200, @voucher_payload)

        "/journals/7/vouchers/2026-3/attachment" ->
          json_resp(conn, 200, ~s({"name": "alt.pdf", "id": 9}))

        "/journals/7/vouchers/2026-3/attachment/file" ->
          # No content-type header on the raw file response.
          Plug.Conn.send_resp(conn, 200, "raw-bytes")
      end
    end)

    assert {:ok, %AttachmentEvidence{} = evidence} =
             Economic.get_voucher_attachment(context(), {:voucher, "3"})

    assert evidence.filename == "alt.pdf"
    assert evidence.content_type == "application/pdf"
    assert evidence.external_attachment_id == "9"
  end

  test "attachment metadata errors classify; transport losses are provider failures" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" -> json_resp(conn, 200, @voucher_payload)
        "/journals/7/vouchers/2026-3/attachment" -> json_resp(conn, 500, ~s({}))
      end
    end)

    assert {:error, {:provider_failure, 500}} =
             Economic.get_voucher_attachment(context(), {:voucher, "3"})

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" -> json_resp(conn, 200, @voucher_payload)
        "/journals/7/vouchers/2026-3/attachment" -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, {:provider_failure, :timeout}} =
             Economic.get_voucher_attachment(context(), {:voucher, "3"})
  end

  test "attachment file errors classify; transport losses are provider failures" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" ->
          json_resp(conn, 200, @voucher_payload)

        "/journals/7/vouchers/2026-3/attachment" ->
          json_resp(conn, 200, ~s({"fileName": "evidence.pdf"}))

        "/journals/7/vouchers/2026-3/attachment/file" ->
          json_resp(conn, 500, ~s({}))
      end
    end)

    assert {:error, {:provider_failure, 500}} =
             Economic.get_voucher_attachment(context(), {:voucher, "3"})

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers/2026-3" ->
          json_resp(conn, 200, @voucher_payload)

        "/journals/7/vouchers/2026-3/attachment" ->
          json_resp(conn, 200, ~s({"fileName": "evidence.pdf"}))

        "/journals/7/vouchers/2026-3/attachment/file" ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, {:provider_failure, :timeout}} =
             Economic.get_voucher_attachment(context(), {:voucher, "3"})
  end

  test "get_voucher_attachment resolves by external reference too" do
    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/journals/7/vouchers" ->
          json_resp(conn, 200, ~s({"collection": [#{@voucher_payload}]}))

        "/journals/7/vouchers/2026-3/attachment" ->
          json_resp(conn, 404, ~s({}))
      end
    end)

    assert {:ok, nil} =
             Economic.get_voucher_attachment(context(), {:external_reference, @reference})
  end
end
