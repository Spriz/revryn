defmodule BillingCore.ERP.FakeERPTest do
  use ExUnit.Case, async: true

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.ERP.{CanonicalInvoice, Document, FakeERP, Fingerprint}
  alias BillingCore.ERP.CanonicalInvoice.Line

  setup do
    server = start_supervised!(FakeERP)
    %{server: server, ctx: FakeERP.connection_context(server)}
  end

  defp invoice(overrides \\ []) do
    period = Period.new!(~D[2026-09-15], ~D[2027-09-15])

    base = %CanonicalInvoice{
      external_reference: "abc:t1:intent-1:v1",
      document_type: :invoice,
      customer_external_id: "1001",
      recipient: %{legal_name: "Example ApS", country: "DK"},
      invoice_date: ~D[2026-09-01],
      currency: "DKK",
      payment_term_external_id: "14",
      layout_external_id: "21",
      delivery_mode: :none,
      lines: [
        %Line{
          order: 0,
          line_key: "sub:1:annual:2026-09-15",
          product_external_id: "SAAS-ANNUAL",
          description: "Annual platform subscription — 2026-09-15 to 2027-09-14",
          amount: Money.new!("DKK", 12_000_000),
          recognition: {:over_time, period}
        },
        %Line{
          order: 1,
          line_key: "setup:1",
          product_external_id: "SETUP",
          description: "Setup fee | Ref: setup1",
          amount: Money.new!("DKK", 50_000),
          recognition: :point_in_time
        }
      ]
    }

    struct!(base, overrides)
  end

  describe "create_draft/3 and read-back" do
    test "stores a normalized draft document with fingerprints and net amount", %{ctx: ctx} do
      inv = invoice()

      assert {:ok, %Document{} = doc} = FakeERP.create_draft(ctx, inv, "op-create-1")

      assert doc.state == :draft
      assert doc.external_draft_id == "1"
      assert doc.external_booked_number == nil
      assert doc.external_reference == inv.external_reference
      assert doc.customer_external_id == "1001"
      assert doc.invoice_date == ~D[2026-09-01]
      assert doc.currency == "DKK"
      assert doc.payment_term_external_id == "14"
      assert doc.layout_external_id == "21"
      assert doc.recipient_fingerprint == Fingerprint.recipient(inv.recipient)
      assert is_binary(doc.customer_snapshot_fingerprint)
      assert is_binary(doc.external_hash)

      [line0, line1] = doc.lines

      assert line0.description_fingerprint ==
               Fingerprint.description(Enum.at(inv.lines, 0).description)

      assert line0.recognition == {:over_time, ~D[2026-09-15], ~D[2027-09-15]}
      assert line1.recognition == :point_in_time
      assert Document.net_amount(doc) == Money.new!("DKK", 12_050_000)

      # Read-back through every ref type returns the same document.
      assert {:ok, ^doc} = FakeERP.get_document(ctx, {:draft, "1"})

      assert {:ok, ^doc} =
               FakeERP.get_document(ctx, {:external_reference, inv.external_reference})

      assert {:ok, ^doc} = FakeERP.find_document(ctx, inv.external_reference)
    end

    test "draft ids increment per instance", %{ctx: ctx} do
      assert {:ok, %Document{external_draft_id: "1"}} =
               FakeERP.create_draft(ctx, invoice(), "op-1")

      assert {:ok, %Document{external_draft_id: "2"}} =
               FakeERP.create_draft(
                 ctx,
                 invoice(external_reference: "abc:t1:intent-2:v1"),
                 "op-2"
               )
    end

    test "a second create with the same external_reference conflicts", %{ctx: ctx} do
      assert {:ok, _} = FakeERP.create_draft(ctx, invoice(), "op-1")

      assert {:error, {:conflict, %{reason: :duplicate_external_reference}}} =
               FakeERP.create_draft(ctx, invoice(), "op-2")
    end

    test "find_document returns {:ok, nil} when absent", %{ctx: ctx} do
      assert {:ok, nil} = FakeERP.find_document(ctx, "abc:t1:missing:v1")
    end

    test "instances are isolated", %{ctx: ctx} do
      other = start_supervised!({FakeERP, []}, id: :other_fake)
      other_ctx = FakeERP.connection_context(other)

      assert {:ok, _} = FakeERP.create_draft(ctx, invoice(), "op-1")
      assert {:ok, nil} = FakeERP.find_document(other_ctx, invoice().external_reference)
    end
  end

  describe "idempotency-key replay (SPEC §17.7)" do
    test "replay within the window returns the original result without duplicating", %{
      ctx: ctx,
      server: server
    } do
      assert {:ok, doc} = FakeERP.create_draft(ctx, invoice(), "op-create-1")
      assert {:ok, ^doc} = FakeERP.create_draft(ctx, invoice(), "op-create-1")
      assert [%Document{external_draft_id: "1"}] = FakeERP.list_documents(server)
    end

    test "replay after cache expiry hits the reference conflict, forcing search-first", %{
      ctx: ctx,
      server: server
    } do
      assert {:ok, _doc} = FakeERP.create_draft(ctx, invoice(), "op-create-1")
      :ok = FakeERP.expire_idempotency_cache(server)

      # SPEC §17.7: reusing the old key without a read is insufficient evidence.
      assert {:error, {:conflict, %{reason: :duplicate_external_reference}}} =
               FakeERP.create_draft(ctx, invoice(), "op-create-1")

      # The correct recovery path still finds the committed draft.
      assert {:ok, %Document{state: :draft}} =
               FakeERP.find_document(ctx, invoice().external_reference)
    end

    test "a configured finite window expires without an explicit call" do
      server = start_supervised!({FakeERP, idempotency_window_ms: 0}, id: :zero_window)
      ctx = FakeERP.connection_context(server)

      assert {:ok, _} = FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:error, {:conflict, %{reason: :duplicate_external_reference}}} =
               FakeERP.create_draft(ctx, invoice(), "op-create-1")
    end

    test "errors are not cached for replay", %{ctx: ctx} do
      assert {:ok, _} = FakeERP.create_draft(ctx, invoice(), "op-1")

      assert {:error, {:conflict, _}} =
               FakeERP.create_draft(ctx, invoice(), "op-2")

      # The same key succeeds once the underlying cause is fixed.
      assert {:ok, _} =
               FakeERP.create_draft(
                 ctx,
                 invoice(external_reference: "abc:t1:intent-2:v1"),
                 "op-2"
               )
    end
  end

  describe "unknown outcome — response lost after commit (SPEC §23.4 item 12)" do
    test "create_draft performs the side effect but returns {:unknown, hint}", %{
      ctx: ctx,
      server: server
    } do
      :ok = FakeERP.inject_unknown_outcome(server, :create_draft)
      inv = invoice()

      assert {:unknown, hint} = FakeERP.create_draft(ctx, inv, "op-create-1")
      assert hint.search_by == [{:external_reference, inv.external_reference}]

      # The draft was actually committed; recovery by reference finds it.
      assert {:ok, %Document{state: :draft, external_draft_id: draft_id}} =
               FakeERP.find_document(ctx, inv.external_reference)

      # Provider cached the committed outcome: same-key retry replays it.
      assert {:ok, %Document{external_draft_id: ^draft_id}} =
               FakeERP.create_draft(ctx, inv, "op-create-1")

      # One-shot: the next create behaves normally.
      assert {:ok, %Document{}} =
               FakeERP.create_draft(
                 ctx,
                 invoice(external_reference: "abc:t1:intent-2:v1"),
                 "op-2"
               )
    end

    test "book_document performs the booking but loses the response", %{ctx: ctx, server: server} do
      test_pid = self()
      :ok = FakeERP.set_webhook_sink(server, &send(test_pid, {:webhook, &1}))

      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      :ok = FakeERP.inject_unknown_outcome(server, :book_document)

      assert {:unknown, hint} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :none},
                 "op-book-1"
               )

      assert {:booked, number} =
               Enum.find(hint.search_by, &match?({:booked, _}, &1))

      assert {:ok, %Document{state: :booked}} = FakeERP.get_document(ctx, {:booked, number})

      # The provider still emits the webhook for the committed booking.
      assert_receive {:webhook, %{event: "invoice.booked", booked_number: ^number}}

      # Same-key retry replays the committed booking.
      assert {:ok, %Document{state: :booked, external_booked_number: ^number}} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :none},
                 "op-book-1"
               )
    end
  end

  describe "update_draft/4" do
    test "fully replaces header and lines and changes the external hash", %{ctx: ctx} do
      {:ok, original} = FakeERP.create_draft(ctx, invoice(), "op-create-1")

      updated_invoice =
        invoice(
          invoice_date: ~D[2026-09-02],
          lines: [
            %Line{
              order: 0,
              line_key: "setup:1",
              product_external_id: "SETUP",
              description: "Setup fee (revised) | Ref: setup1",
              amount: Money.new!("DKK", 75_000),
              recognition: :point_in_time
            }
          ]
        )

      assert {:ok, %Document{} = doc} =
               FakeERP.update_draft(
                 ctx,
                 {:draft, original.external_draft_id},
                 updated_invoice,
                 "op-update-1"
               )

      assert doc.external_draft_id == original.external_draft_id
      assert doc.invoice_date == ~D[2026-09-02]
      assert [%{amount: %Money{minor_units: 75_000}}] = doc.lines
      assert doc.external_hash != original.external_hash
      assert {:ok, ^doc} = FakeERP.get_document(ctx, {:draft, original.external_draft_id})
    end

    test "returns {:not_found, _} when the draft is gone", %{ctx: ctx} do
      assert {:error, {:not_found, {:draft, "999"}}} =
               FakeERP.update_draft(ctx, {:draft, "999"}, invoice(), "op-update-1")
    end

    test "returns {:conflict, :booked} when the draft was already booked", %{ctx: ctx} do
      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      {:ok, _} =
        FakeERP.book_document(ctx, {:draft, draft_id}, %{delivery_mode: :none}, "op-book-1")

      assert {:error, {:conflict, :booked}} =
               FakeERP.update_draft(ctx, {:draft, draft_id}, invoice(), "op-update-1")

      assert {:error, {:conflict, :booked}} =
               FakeERP.update_draft(
                 ctx,
                 {:external_reference, invoice().external_reference},
                 invoice(),
                 "op-update-2"
               )
    end
  end

  describe "book_document/4" do
    test "transitions draft→booked with an incrementing number, preserving accrual fields", %{
      ctx: ctx
    } do
      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:ok, %Document{} = booked} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :email},
                 "op-book-1"
               )

      assert booked.state == :booked
      assert booked.external_booked_number == "1001"
      assert booked.external_draft_id == draft_id
      assert booked.provider_extras.delivery_mode == :email

      # Accrual (recognition) dates survive booking (SPEC §17.10 step 7).
      assert [
               %{recognition: {:over_time, ~D[2026-09-15], ~D[2027-09-15]}},
               %{recognition: :point_in_time}
             ] = booked.lines

      # The draft is gone; the booked document is found by number and reference.
      assert {:error, {:not_found, {:draft, ^draft_id}}} =
               FakeERP.get_document(ctx, {:draft, draft_id})

      assert {:ok, ^booked} = FakeERP.get_document(ctx, {:booked, "1001"})
      assert {:ok, ^booked} = FakeERP.find_document(ctx, invoice().external_reference)
    end

    test "booking twice conflicts; replay by operation key is idempotent", %{ctx: ctx} do
      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:ok, booked} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :none},
                 "op-book-1"
               )

      assert {:ok, ^booked} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :none},
                 "op-book-1"
               )

      assert {:error, {:conflict, :already_booked}} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :none},
                 "op-book-2"
               )
    end

    test "unsupported delivery mode is a validation error", %{ctx: ctx} do
      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:error, {:validation, [%{field: :delivery_mode, code: :unsupported_delivery_mode}]}} =
               FakeERP.book_document(
                 ctx,
                 {:draft, draft_id},
                 %{delivery_mode: :einvoice},
                 "op-book-1"
               )
    end

    test "booking a missing draft is not_found", %{ctx: ctx} do
      assert {:error, {:not_found, {:draft, "42"}}} =
               FakeERP.book_document(ctx, {:draft, "42"}, %{delivery_mode: :none}, "op-book-1")
    end
  end

  describe "human_edit_draft/3 (SPEC §17.9 step 4)" do
    test "changes the external_hash so callers can detect drift", %{ctx: ctx, server: server} do
      {:ok, %Document{external_draft_id: draft_id, external_hash: original_hash}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:ok, %Document{} = edited} =
               FakeERP.human_edit_draft(server, draft_id, fn doc ->
                 %{
                   doc
                   | lines:
                       Enum.map(doc.lines, fn
                         %{order: 0} = line ->
                           %{
                             line
                             | amount: Money.new!("DKK", 11_000_000),
                               description: "Discounted by a helpful human"
                           }

                         line ->
                           line
                       end)
                 }
               end)

      assert edited.external_hash != original_hash
      assert edited.state == :draft
      assert edited.external_draft_id == draft_id

      [line0 | _] = edited.lines
      assert line0.amount == Money.new!("DKK", 11_000_000)

      assert line0.description_fingerprint ==
               Fingerprint.description("Discounted by a helpful human")

      # The stored draft reflects the human edit on the next read.
      assert {:ok, ^edited} = FakeERP.get_document(ctx, {:draft, draft_id})
    end

    test "editing a missing draft is not_found", %{server: server} do
      assert {:error, {:not_found, {:draft, "77"}}} =
               FakeERP.human_edit_draft(server, "77", & &1)
    end
  end

  describe "failure injection" do
    test "rate limit returns retry metadata and is one-shot", %{ctx: ctx, server: server} do
      :ok =
        FakeERP.inject_failure(
          server,
          :create_draft,
          {:error, {:rate_limited, %{retry_after: 30}}}
        )

      assert {:error, {:rate_limited, %{retry_after: 30}}} =
               FakeERP.create_draft(ctx, invoice(), "op-create-1")

      # Consumed: the retry succeeds and no side effect happened on the 429.
      assert {:ok, %Document{external_draft_id: "1"}} =
               FakeERP.create_draft(ctx, invoice(), "op-create-1")
    end

    test "validation and provider failures are returned verbatim", %{ctx: ctx, server: server} do
      errors = [%{field: :product, code: :unknown_product, detail: "SAAS-ANNUAL missing"}]
      :ok = FakeERP.inject_failure(server, :create_draft, {:error, {:validation, errors}})

      :ok =
        FakeERP.inject_failure(server, :get_document, {:error, {:provider_failure, :http_500}})

      assert {:error, {:validation, ^errors}} = FakeERP.create_draft(ctx, invoice(), "op-1")
      assert {:error, {:provider_failure, :http_500}} = FakeERP.get_document(ctx, {:draft, "1"})
    end

    test "queued one-shot injections are consumed FIFO", %{ctx: ctx, server: server} do
      :ok =
        FakeERP.inject_failure(
          server,
          :find_document,
          {:error, {:rate_limited, %{retry_after: 1}}}
        )

      :ok =
        FakeERP.inject_failure(server, :find_document, {:error, {:provider_failure, :timeout}})

      assert {:error, {:rate_limited, %{retry_after: 1}}} = FakeERP.find_document(ctx, "ref")
      assert {:error, {:provider_failure, :timeout}} = FakeERP.find_document(ctx, "ref")
      assert {:ok, nil} = FakeERP.find_document(ctx, "ref")
    end

    test "sticky injections persist until cleared", %{ctx: ctx, server: server} do
      :ok =
        FakeERP.inject_failure(server, :preflight, {:error, {:authentication, :invalid_token}},
          mode: :sticky
        )

      assert {:error, {:authentication, :invalid_token}} = FakeERP.preflight(ctx, %{})
      assert {:error, {:authentication, :invalid_token}} = FakeERP.preflight(ctx, %{})

      :ok = FakeERP.clear_injections(server)
      assert {:ok, %{checks: _}} = FakeERP.preflight(ctx, %{})
    end
  end

  describe "webhooks (SPEC §17.11, BC-US-086)" do
    test "sink receives booked events from external booking, including duplicates", %{
      ctx: ctx,
      server: server
    } do
      test_pid = self()
      :ok = FakeERP.set_webhook_sink(server, &send(test_pid, {:webhook, &1}))

      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:ok, %Document{state: :booked, external_booked_number: number}} =
               FakeERP.book_externally(server, draft_id)

      assert_receive {:webhook,
                      %{event: "invoice.booked", draft_id: ^draft_id, booked_number: ^number} =
                        event}

      assert event.external_reference == invoice().external_reference

      # At-least-once delivery: the same event can arrive again.
      :ok = FakeERP.deliver_duplicate_webhook(server, number)
      assert_receive {:webhook, ^event}

      # The externally booked document is visible like any other booking.
      assert {:error, {:conflict, :booked}} =
               FakeERP.update_draft(ctx, {:draft, draft_id}, invoice(), "op-update-1")
    end

    test "webhook loss: booking with webhook: :drop never reaches the sink", %{
      ctx: ctx,
      server: server
    } do
      test_pid = self()
      :ok = FakeERP.set_webhook_sink(server, &send(test_pid, {:webhook, &1}))

      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      assert {:ok, %Document{external_booked_number: number}} =
               FakeERP.book_externally(server, draft_id, webhook: :drop)

      refute_received {:webhook, _}

      # The lost event can still be re-delivered later (poller/duplicate path).
      :ok = FakeERP.deliver_duplicate_webhook(server, number)
      assert_receive {:webhook, %{event: "invoice.booked", booked_number: ^number}}
    end

    test "booking through the adapter also notifies the sink", %{ctx: ctx, server: server} do
      test_pid = self()
      :ok = FakeERP.set_webhook_sink(server, &send(test_pid, {:webhook, &1}))

      {:ok, %Document{external_draft_id: draft_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-create-1")

      {:ok, %Document{external_booked_number: number}} =
        FakeERP.book_document(ctx, {:draft, draft_id}, %{delivery_mode: :none}, "op-book-1")

      assert_receive {:webhook, %{event: "invoice.booked", booked_number: ^number}}

      # Idempotent replay does not re-deliver.
      {:ok, _} =
        FakeERP.book_document(ctx, {:draft, draft_id}, %{delivery_mode: :none}, "op-book-1")

      refute_received {:webhook, _}
    end

    test "duplicate delivery for an unknown booking is not_found", %{server: server} do
      assert {:error, {:not_found, {:booked, "9999"}}} =
               FakeERP.deliver_duplicate_webhook(server, "9999")
    end
  end

  describe "capabilities and preflight" do
    test "capabilities are the full happy map", %{ctx: ctx} do
      assert {:ok, caps} = FakeERP.capabilities(ctx)

      assert caps == %{
               supports_draft_invoices: true,
               supports_draft_updates: true,
               supports_booking: true,
               supports_invoice_webhooks: true,
               supports_line_accrual_periods: true,
               supports_customer_provisioning: true,
               supports_customer_credit_settlements: false,
               supports_finance_vouchers: true,
               supports_voucher_attachments: true,
               supported_delivery_modes: [:none, :email],
               amount_scale: 2,
               quantity_scale: 2
             }
    end

    test "preflight returns configurable checks with capabilities and evidence", %{
      ctx: ctx,
      server: server
    } do
      assert {:ok, %{checks: checks, capabilities: %{supports_booking: true}, evidence: evidence}} =
               FakeERP.preflight(ctx, %{product_external_ids: ["SAAS-ANNUAL"]})

      assert Enum.all?(checks, &(&1.status == :pass))
      assert evidence.provider == :fake_erp

      failing = [%{check: :accruals_module, status: :fail, detail: "accruals module disabled"}]
      :ok = FakeERP.set_preflight_checks(server, failing)

      assert {:ok, %{checks: ^failing}} = FakeERP.preflight(ctx, %{})
    end
  end

  describe "list_documents/1" do
    test "returns drafts then booked documents for assertions", %{ctx: ctx, server: server} do
      {:ok, %Document{external_draft_id: first_id}} =
        FakeERP.create_draft(ctx, invoice(), "op-1")

      {:ok, _} =
        FakeERP.create_draft(ctx, invoice(external_reference: "abc:t1:intent-2:v1"), "op-2")

      {:ok, _} =
        FakeERP.book_document(ctx, {:draft, first_id}, %{delivery_mode: :none}, "op-book")

      assert [
               %Document{state: :draft, external_draft_id: "2"},
               %Document{state: :booked, external_booked_number: "1001"}
             ] = FakeERP.list_documents(server)
    end
  end
end
