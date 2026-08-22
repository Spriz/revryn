defmodule BillingCore.ERP.FakeERPSnapshotTest do
  use ExUnit.Case, async: false

  alias BillingCore.Domain.Money
  alias BillingCore.ERP.{CanonicalInvoice, FakeERP}
  alias BillingCore.ERP.CanonicalInvoice.Line
  alias BillingCore.ERP.Vouchers.{AttachmentEvidence, FinanceVoucher, FinanceVoucherLine}

  defp invoice(reference) do
    %CanonicalInvoice{
      external_reference: reference,
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Example ApS", country: "DK"},
      invoice_date: ~D[2026-08-31],
      currency: "DKK",
      lines: [
        %Line{
          order: 0,
          line_key: "line-1",
          product_external_id: "SUBSCRIPTION",
          description: "Monthly subscription",
          amount: Money.new!("DKK", 12_500),
          recognition: :point_in_time
        }
      ]
    }
  end

  defp voucher do
    %FinanceVoucher{
      external_reference: "REVRYN:CREDIT-CLOSE:close-1:2026-08:DKK",
      accounting_date: ~D[2026-08-31],
      accounting_year_external_id: "2026",
      journal_external_id: "1",
      currency: "DKK",
      lines: [
        %FinanceVoucherLine{
          line_key: "liability",
          account_external_id: "2990",
          amount: Money.new!("DKK", -500),
          role: :customer_credit_liability
        },
        %FinanceVoucherLine{
          line_key: "offset",
          account_external_id: "5890",
          amount: Money.new!("DKK", 500),
          role: :balancing
        }
      ]
    }
  end

  defp report do
    content = "%PDF-fake-close"

    %AttachmentEvidence{
      filename: "close.pdf",
      content_type: "application/pdf",
      content: content,
      byte_size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }
  end

  test "round-trips drafts, booked documents, vouchers and attachments" do
    server = start_supervised!(FakeERP)
    ctx = FakeERP.connection_context(server)

    assert {:ok, draft} = FakeERP.create_draft(ctx, invoice("draft-ref"), "draft-op")
    assert {:ok, booked_draft} = FakeERP.create_draft(ctx, invoice("booked-ref"), "book-op")

    assert {:ok, booked} =
             FakeERP.book_document(
               ctx,
               {:draft, booked_draft.external_draft_id},
               %{delivery_mode: :none},
               "book-document-op"
             )

    assert {:ok, stored_voucher} = FakeERP.create_finance_voucher(ctx, voucher(), "voucher-op")

    assert :ok =
             FakeERP.attach_voucher_report(
               ctx,
               {:voucher, stored_voucher.external_voucher_number},
               report(),
               "report-op"
             )

    assert {:ok, snapshot} = FakeERP.export_snapshot(server)

    restored = start_supervised!({FakeERP, snapshot: snapshot}, id: :restored_fake_erp)
    restored_ctx = FakeERP.connection_context(restored)

    assert {:ok, restored_draft} =
             FakeERP.get_document(restored_ctx, {:draft, draft.external_draft_id})

    assert restored_draft.external_reference == "draft-ref"

    assert {:ok, restored_booked} =
             FakeERP.get_document(restored_ctx, {:booked, booked.external_booked_number})

    assert restored_booked.external_reference == "booked-ref"
    assert {:ok, restored_voucher} = FakeERP.get_finance_voucher(restored_ctx, {:voucher, "1"})
    assert restored_voucher.external_reference == voucher().external_reference

    assert {:ok, %AttachmentEvidence{sha256: sha256, content: nil}} =
             FakeERP.get_voucher_attachment(restored_ctx, {:voucher, "1"})

    assert sha256 == report().sha256
  end

  test "rejects a tampered snapshot hash" do
    server = start_supervised!(FakeERP)
    assert {:ok, snapshot} = FakeERP.export_snapshot(server)

    tampered = %{snapshot | sha256: String.duplicate("0", 64)}

    assert {:error, {:invalid_snapshot, :sha256_mismatch}} =
             FakeERP.start_link(snapshot: tampered)
  end

  test "persists synchronously after a committed provider mutation" do
    test_pid = self()

    server =
      start_supervised!(
        {FakeERP,
         persist_snapshot: fn snapshot ->
           send(test_pid, {:persisted, snapshot})
           :ok
         end}
      )

    ctx = FakeERP.connection_context(server)
    assert {:ok, _draft} = FakeERP.create_draft(ctx, invoice("callback-ref"), "callback-op")
    assert_receive {:persisted, %{format_version: 1, payload: payload, sha256: hash}}
    assert is_binary(payload)
    assert hash == :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  test "persistence failure returns unknown, blocks reads, then recovers the one committed effect" do
    persistence =
      start_supervised!(
        {Agent,
         fn ->
           :fail
         end}
      )

    server =
      start_supervised!(
        {FakeERP,
         persist_snapshot: fn _snapshot ->
           Agent.get_and_update(persistence, fn
             :fail -> {{:error, :database_unavailable}, :fail}
             :ok -> {:ok, :ok}
           end)
         end}
      )

    ctx = FakeERP.connection_context(server)

    assert {:unknown, %{detail: "demo ERP snapshot persistence failed"}} =
             FakeERP.create_draft(ctx, invoice("dirty-ref"), "dirty-create")

    assert {:error, {:provider_failure, :snapshot_persistence_failed}} =
             FakeERP.get_document(ctx, {:external_reference, "dirty-ref"})

    Agent.update(persistence, fn _state -> :ok end)

    assert {:ok, document} = FakeERP.find_document(ctx, "dirty-ref")
    assert document.external_reference == "dirty-ref"
    assert [^document] = FakeERP.list_documents(server)
  end

  test "a crash after persistence failure restores the last durable snapshot and safely retries" do
    persistence = start_supervised!({Agent, fn -> :fail end})

    persist_snapshot = fn _snapshot ->
      Agent.get_and_update(persistence, fn
        :fail -> {{:error, :database_unavailable}, :fail}
        :ok -> {:ok, :ok}
      end)
    end

    server =
      start_supervised!(
        {FakeERP, persist_snapshot: persist_snapshot},
        id: :crash_recovery_fake_erp
      )

    assert {:ok, last_durable_snapshot} = FakeERP.export_snapshot(server)
    context = FakeERP.connection_context(server)

    assert {:unknown, %{detail: "demo ERP snapshot persistence failed"}} =
             FakeERP.create_draft(context, invoice("crash-ref"), "crash-create")

    assert :ok = stop_supervised(:crash_recovery_fake_erp)
    Agent.update(persistence, fn _state -> :ok end)

    restored =
      start_supervised!(
        {FakeERP, snapshot: last_durable_snapshot, persist_snapshot: persist_snapshot},
        id: :restored_after_failed_persistence
      )

    restored_context = FakeERP.connection_context(restored)
    assert {:ok, nil} = FakeERP.find_document(restored_context, "crash-ref")

    assert {:ok, document} =
             FakeERP.create_draft(restored_context, invoice("crash-ref"), "crash-retry")

    assert document.external_reference == "crash-ref"
    assert [^document] = FakeERP.list_documents(restored)
  end
end
