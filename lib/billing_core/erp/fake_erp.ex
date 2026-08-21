defmodule BillingCore.ERP.FakeERP do
  @moduledoc """
  Stateful fake ERP server for deterministic contract tests (SPEC §23.5).

  Implements the `BillingCore.ERP.Adapter` behaviour with provider-realistic
  semantics so failure paths are reproducible in CI:

    * idempotency-key replay within a configurable window (SPEC §17.7 — the
      provider response cache is short-lived; `expire_idempotency_cache/1`
      simulates the ~1h expiry so callers must search before re-creating);
    * draft creation/update/booking with an incrementing external draft id and
      booked invoice number, external-reference uniqueness per connection, and
      accrual (recognition) fields preserved on booked lines;
    * configurable failure injection (`inject_failure/4`) for validation
      errors, rate limits with retry metadata, provider failures, etc.;
    * response loss after commit (`inject_unknown_outcome/2`) — the side
      effect happens but the caller receives `{:unknown, recovery_hint}`
      (SPEC §23.4 item 12);
    * human mutation of a draft (`human_edit_draft/3`) which bumps the
      document's `external_hash` so drift is detectable (SPEC §17.9 step 4);
    * external booking (`book_externally/3`, BC-US-086) with webhook delivery,
      duplication (`deliver_duplicate_webhook/2`), and loss (`webhook: :drop`).

  State lives in a GenServer started per test via `start_supervised!/1`. The
  server pid (or registered name) travels in the `connection_context` map
  under `:fake_server`, so concurrent async tests never share state.

  Webhook sinks are invoked from within the server process; they must not
  call back into the same fake synchronously (send a message instead).

  The fake is not a substitute for sandbox tests; it makes failure paths
  deterministic in CI.
  """

  @behaviour BillingCore.ERP.Adapter

  use GenServer

  alias BillingCore.Domain.{Canonical, Period}
  alias BillingCore.ERP.{CanonicalInvoice, Document, Fingerprint}
  alias BillingCore.ERP.CanonicalInvoice.Line

  @operations [
    :capabilities,
    :preflight,
    :find_document,
    :create_draft,
    :update_draft,
    :get_document,
    :book_document
  ]

  @write_operations [:create_draft, :update_draft, :book_document]

  @default_capabilities %{
    supports_draft_invoices: true,
    supports_draft_updates: true,
    supports_booking: true,
    supports_invoice_webhooks: true,
    supports_line_accrual_periods: true,
    supports_customer_provisioning: true,
    supported_delivery_modes: [:none, :email],
    amount_scale: 2,
    quantity_scale: 2
  }

  @default_preflight_checks [
    %{check: :agreement, status: :pass, detail: "agreement 123456, base currency DKK"},
    %{check: :roles, status: :pass, detail: "sales and bookkeeping roles granted"},
    %{check: :accruals_module, status: :pass, detail: "accruals module enabled"},
    %{check: :layout, status: :pass, detail: "layout accessible"},
    %{check: :payment_terms, status: :pass, detail: "payment terms accessible"},
    %{check: :api_health, status: :pass, detail: "no-write health check ok"}
  ]

  ## Lifecycle

  @doc """
  Starts a fake ERP instance.

  Options:

    * `:name` — optional registered name;
    * `:idempotency_window_ms` — provider idempotency-cache lifetime in
      milliseconds, default `:infinity` (effectively infinite for tests);
    * `:capabilities` — override the default happy capabilities map;
    * `:preflight_checks` — override the default all-pass preflight checks.
  """
  def start_link(opts \\ []) do
    {name_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @doc """
  Convenience `connection_context` for tests: fresh connection/team ids with
  `:fake_server` pointing at this instance.
  """
  @spec connection_context(GenServer.server(), map()) :: map()
  def connection_context(server, overrides \\ %{}) do
    Map.merge(
      %{
        connection_id: Ecto.UUID.generate(),
        team_id: Ecto.UUID.generate(),
        provider: :fake_erp,
        fake_server: server
      },
      overrides
    )
  end

  ## Adapter callbacks (run in the caller; state access goes through the server)

  @impl BillingCore.ERP.Adapter
  def capabilities(ctx), do: call(ctx, :capabilities)

  @impl BillingCore.ERP.Adapter
  def preflight(ctx, input), do: call(ctx, {:preflight, input})

  @impl BillingCore.ERP.Adapter
  def find_document(ctx, external_reference) when is_binary(external_reference),
    do: call(ctx, {:find_document, external_reference})

  @impl BillingCore.ERP.Adapter
  def create_draft(ctx, %CanonicalInvoice{} = invoice, operation_key),
    do: call(ctx, {:create_draft, invoice, operation_key})

  @impl BillingCore.ERP.Adapter
  def update_draft(ctx, document_ref, %CanonicalInvoice{} = invoice, operation_key),
    do: call(ctx, {:update_draft, document_ref, invoice, operation_key})

  @impl BillingCore.ERP.Adapter
  def get_document(ctx, document_ref), do: call(ctx, {:get_document, document_ref})

  @impl BillingCore.ERP.Adapter
  def book_document(ctx, document_ref, booking_options, operation_key),
    do: call(ctx, {:book_document, document_ref, booking_options, operation_key})

  defp call(%{fake_server: server}, request), do: GenServer.call(server, request)

  ## Test-control API

  @doc """
  Queues `response` as the result of the next `operation` call. One-shot by
  default; pass `mode: :sticky` to keep returning it until `clear_injections/1`.
  Multiple one-shot injections for the same operation are consumed FIFO.
  """
  def inject_failure(server, operation, response, opts \\ []) when operation in @operations do
    mode = Keyword.get(opts, :mode, :once)

    unless mode in [:once, :sticky] do
      raise ArgumentError, "mode must be :once or :sticky, got: #{inspect(mode)}"
    end

    GenServer.call(server, {:inject_failure, operation, response, mode})
  end

  @doc """
  The next `operation` call performs its side effect but the response is lost:
  the caller receives `{:unknown, recovery_hint}` (SPEC §23.4 item 12). The
  provider still caches the real outcome under the idempotency key, and a
  booked-invoice webhook still fires, matching real "timeout after commit".
  """
  def inject_unknown_outcome(server, operation) when operation in @write_operations do
    GenServer.call(server, {:inject_unknown_outcome, operation})
  end

  @doc "Removes all queued failure injections and pending unknown outcomes."
  def clear_injections(server), do: GenServer.call(server, :clear_injections)

  @doc """
  Drops all cached idempotency-key responses, simulating expiry of the
  provider's ~1h response cache (SPEC §17.7). A replayed create then hits the
  external-reference uniqueness conflict, forcing callers to search first.
  """
  def expire_idempotency_cache(server), do: GenServer.call(server, :expire_idempotency_cache)

  @doc """
  Simulates a human editing the draft in the ERP UI (SPEC §17.9 step 4).
  `fun` receives the stored `%Document{}` and returns the edited document;
  line description fingerprints and the `external_hash` are recomputed so
  callers can detect the drift. State and draft id are preserved.
  """
  def human_edit_draft(server, draft_id, fun) when is_function(fun, 1) do
    GenServer.call(server, {:human_edit_draft, draft_id, fun})
  end

  @doc """
  Books a draft outside Billing Core (BC-US-086). Delivers an
  `invoice.booked` event to the webhook sink unless `webhook: :drop`.
  """
  def book_externally(server, draft_id, opts \\ []) do
    GenServer.call(server, {:book_externally, draft_id, opts})
  end

  @doc """
  Registers a webhook sink invoked with
  `%{event: "invoice.booked", draft_id: ..., booked_number: ..., external_reference: ...}`
  on every booking. Pass `nil` to clear.
  """
  def set_webhook_sink(server, fun) when is_function(fun, 1) or is_nil(fun) do
    GenServer.call(server, {:set_webhook_sink, fun})
  end

  @doc "Re-delivers the `invoice.booked` event for `booked_number` (at-least-once duplication)."
  def deliver_duplicate_webhook(server, booked_number) do
    GenServer.call(server, {:deliver_duplicate_webhook, booked_number})
  end

  @doc "All stored documents (drafts then booked, in id order) for assertions."
  def list_documents(server), do: GenServer.call(server, :list_documents)

  @doc "Replaces the preflight check results returned by `preflight/2`."
  def set_preflight_checks(server, checks) when is_list(checks) do
    GenServer.call(server, {:set_preflight_checks, checks})
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    state = %{
      capabilities: Keyword.get(opts, :capabilities, @default_capabilities),
      preflight_checks: Keyword.get(opts, :preflight_checks, @default_preflight_checks),
      idempotency_window_ms: Keyword.get(opts, :idempotency_window_ms, :infinity),
      drafts: %{},
      booked: %{},
      by_reference: %{},
      next_draft_id: 1,
      next_booked_number: 1001,
      idempotency: %{},
      injections: %{},
      unknown_next: MapSet.new(),
      webhook_sink: nil,
      webhook_events: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:capabilities, _from, state) do
    with_injection(state, :capabilities, fn state ->
      {{:ok, state.capabilities}, state}
    end)
  end

  def handle_call({:preflight, _input}, _from, state) do
    with_injection(state, :preflight, fn state ->
      result = %{
        checks: state.preflight_checks,
        capabilities: state.capabilities,
        evidence: %{
          provider: :fake_erp,
          agreement: "123456",
          base_currency: "DKK",
          checked_at: DateTime.utc_now()
        }
      }

      {{:ok, result}, state}
    end)
  end

  def handle_call({:find_document, external_reference}, _from, state) do
    with_injection(state, :find_document, fn state ->
      case resolve_ref(state, {:external_reference, external_reference}) do
        {_kind, _id, doc} -> {{:ok, doc}, state}
        :not_found -> {{:ok, nil}, state}
      end
    end)
  end

  def handle_call({:get_document, document_ref}, _from, state) do
    with_injection(state, :get_document, fn state ->
      {do_get_document(state, document_ref), state}
    end)
  end

  def handle_call({:create_draft, invoice, op_key}, _from, state) do
    with_injection(state, :create_draft, fn state ->
      hint = fn _result ->
        %{
          search_by: [{:external_reference, invoice.external_reference}],
          detail: "create_draft response lost after commit"
        }
      end

      run_write(state, :create_draft, op_key, hint, &do_create_draft(&1, invoice))
    end)
  end

  def handle_call({:update_draft, document_ref, invoice, op_key}, _from, state) do
    with_injection(state, :update_draft, fn state ->
      hint = fn _result ->
        %{
          search_by: Enum.uniq([document_ref, {:external_reference, invoice.external_reference}]),
          detail: "update_draft response lost after commit"
        }
      end

      run_write(state, :update_draft, op_key, hint, &do_update_draft(&1, document_ref, invoice))
    end)
  end

  def handle_call({:book_document, document_ref, booking_options, op_key}, _from, state) do
    with_injection(state, :book_document, fn state ->
      hint = fn
        {:ok, %Document{} = doc} ->
          %{
            search_by: [
              {:external_reference, doc.external_reference},
              {:booked, doc.external_booked_number}
            ],
            detail: "book_document response lost after commit"
          }

        _other ->
          %{search_by: [document_ref], detail: "book_document response lost"}
      end

      run_write(
        state,
        :book_document,
        op_key,
        hint,
        &do_book_document(&1, document_ref, booking_options)
      )
    end)
  end

  def handle_call({:inject_failure, operation, response, mode}, _from, state) do
    state =
      Map.update!(state, :injections, fn injections ->
        Map.update(injections, operation, [{mode, response}], &(&1 ++ [{mode, response}]))
      end)

    {:reply, :ok, state}
  end

  def handle_call({:inject_unknown_outcome, operation}, _from, state) do
    {:reply, :ok, Map.update!(state, :unknown_next, &MapSet.put(&1, operation))}
  end

  def handle_call(:clear_injections, _from, state) do
    {:reply, :ok, %{state | injections: %{}, unknown_next: MapSet.new()}}
  end

  def handle_call(:expire_idempotency_cache, _from, state) do
    {:reply, :ok, %{state | idempotency: %{}}}
  end

  def handle_call({:human_edit_draft, draft_id, fun}, _from, state) do
    case Map.fetch(state.drafts, draft_id) do
      :error ->
        {:reply, {:error, {:not_found, {:draft, draft_id}}}, state}

      {:ok, doc} ->
        %Document{} = edited = fun.(doc)

        edited = %{
          edited
          | state: :draft,
            external_draft_id: draft_id,
            external_booked_number: nil,
            lines: Enum.map(edited.lines, &refresh_line_fingerprint/1)
        }

        edited = %{edited | external_hash: content_hash(edited)}

        state =
          state
          |> Map.update!(:drafts, &Map.put(&1, draft_id, edited))
          |> reindex_reference(doc.external_reference, edited.external_reference, {
            :draft,
            draft_id
          })

        {:reply, {:ok, edited}, state}
    end
  end

  def handle_call({:book_externally, draft_id, opts}, _from, state) do
    case Map.fetch(state.drafts, draft_id) do
      :error ->
        {:reply, {:error, {:not_found, {:draft, draft_id}}}, state}

      {:ok, _doc} ->
        deliver? = Keyword.get(opts, :webhook, :deliver) == :deliver

        {{:ok, booked}, state} =
          book_draft(state, draft_id, %{delivery_mode: :none, booked_via: :external}, deliver?)

        {:reply, {:ok, booked}, state}
    end
  end

  def handle_call({:set_webhook_sink, fun}, _from, state) do
    {:reply, :ok, %{state | webhook_sink: fun}}
  end

  def handle_call({:deliver_duplicate_webhook, booked_number}, _from, state) do
    case Map.fetch(state.webhook_events, booked_number) do
      {:ok, event} -> {:reply, :ok, deliver_webhook(state, event)}
      :error -> {:reply, {:error, {:not_found, {:booked, booked_number}}}, state}
    end
  end

  def handle_call(:list_documents, _from, state) do
    drafts =
      state.drafts |> Map.values() |> Enum.sort_by(&String.to_integer(&1.external_draft_id))

    booked =
      state.booked |> Map.values() |> Enum.sort_by(&String.to_integer(&1.external_booked_number))

    {:reply, drafts ++ booked, state}
  end

  def handle_call({:set_preflight_checks, checks}, _from, state) do
    {:reply, :ok, %{state | preflight_checks: checks}}
  end

  ## Injection / idempotency / unknown-outcome plumbing

  defp with_injection(state, operation, fun) do
    case pop_injection(state, operation) do
      {nil, state} ->
        {reply, state} = fun.(state)
        {:reply, reply, state}

      {response, state} ->
        {:reply, response, state}
    end
  end

  defp pop_injection(state, operation) do
    case Map.get(state.injections, operation, []) do
      [] ->
        {nil, state}

      [{:once, response} | rest] ->
        {response, Map.update!(state, :injections, &Map.put(&1, operation, rest))}

      [{:sticky, response} | _rest] ->
        {response, state}
    end
  end

  defp run_write(state, operation, op_key, hint_fun, fun) do
    case idempotent_replay(state, op_key) do
      {:hit, result} ->
        {result, state}

      :miss ->
        {unknown?, state} = consume_unknown(state, operation)
        {result, state} = fun.(state)
        state = cache_result(state, op_key, result)

        if unknown? do
          {{:unknown, hint_fun.(result)}, state}
        else
          {result, state}
        end
    end
  end

  defp idempotent_replay(state, op_key) do
    case Map.fetch(state.idempotency, op_key) do
      {:ok, {result, cached_at}} ->
        if within_window?(state, cached_at), do: {:hit, result}, else: :miss

      :error ->
        :miss
    end
  end

  defp within_window?(%{idempotency_window_ms: :infinity}, _cached_at), do: true

  defp within_window?(%{idempotency_window_ms: window_ms}, cached_at) do
    System.monotonic_time(:millisecond) - cached_at < window_ms
  end

  # Only committed outcomes are cached; errors are not replayable.
  defp cache_result(state, op_key, {:ok, _} = result) do
    entry = {result, System.monotonic_time(:millisecond)}
    Map.update!(state, :idempotency, &Map.put(&1, op_key, entry))
  end

  defp cache_result(state, _op_key, _result), do: state

  defp consume_unknown(state, operation) do
    if MapSet.member?(state.unknown_next, operation) do
      {true, Map.update!(state, :unknown_next, &MapSet.delete(&1, operation))}
    else
      {false, state}
    end
  end

  ## Document operations

  defp do_create_draft(state, %CanonicalInvoice{} = invoice) do
    ref = invoice.external_reference

    case Map.fetch(state.by_reference, ref) do
      {:ok, existing} ->
        {{:error,
          {:conflict,
           %{reason: :duplicate_external_reference, external_reference: ref, existing: existing}}},
         state}

      :error ->
        draft_id = Integer.to_string(state.next_draft_id)
        doc = normalize_draft(invoice, draft_id)

        state =
          state
          |> Map.update!(:drafts, &Map.put(&1, draft_id, doc))
          |> Map.update!(:by_reference, &Map.put(&1, ref, {:draft, draft_id}))
          |> Map.put(:next_draft_id, state.next_draft_id + 1)

        {{:ok, doc}, state}
    end
  end

  defp do_update_draft(state, document_ref, %CanonicalInvoice{} = invoice) do
    case resolve_ref(state, document_ref) do
      {:draft, draft_id, old_doc} ->
        new_ref = invoice.external_reference
        conflicting = Map.get(state.by_reference, new_ref)

        if conflicting != nil and conflicting != {:draft, draft_id} do
          {{:error,
            {:conflict, %{reason: :duplicate_external_reference, external_reference: new_ref}}},
           state}
        else
          doc = normalize_draft(invoice, draft_id)

          state =
            state
            |> Map.update!(:drafts, &Map.put(&1, draft_id, doc))
            |> reindex_reference(old_doc.external_reference, new_ref, {:draft, draft_id})

          {{:ok, doc}, state}
        end

      {:booked, _number, _doc} ->
        {{:error, {:conflict, :booked}}, state}

      :not_found ->
        {{:error, {:not_found, document_ref}}, state}
    end
  end

  defp do_book_document(state, document_ref, booking_options) do
    delivery_mode = Map.get(booking_options, :delivery_mode, :none)

    if delivery_mode in state.capabilities.supported_delivery_modes do
      case resolve_ref(state, document_ref) do
        {:draft, draft_id, _doc} ->
          book_draft(state, draft_id, %{delivery_mode: delivery_mode, booked_via: :api}, true)

        {:booked, _number, _doc} ->
          {{:error, {:conflict, :already_booked}}, state}

        :not_found ->
          {{:error, {:not_found, document_ref}}, state}
      end
    else
      {{:error,
        {:validation,
         [
           %{
             field: :delivery_mode,
             code: :unsupported_delivery_mode,
             detail: "delivery mode #{inspect(delivery_mode)} is not supported"
           }
         ]}}, state}
    end
  end

  # Books a draft: assigns the next booked invoice number, preserves accrual
  # (recognition) fields on the lines, and records the invoice.booked event.
  defp book_draft(state, draft_id, extras, deliver_webhook?) do
    draft = Map.fetch!(state.drafts, draft_id)
    number = Integer.to_string(state.next_booked_number)

    booked = %{
      draft
      | state: :booked,
        external_booked_number: number,
        provider_extras: Map.merge(draft.provider_extras, extras)
    }

    booked = %{booked | external_hash: content_hash(booked)}

    event = %{
      event: "invoice.booked",
      draft_id: draft_id,
      booked_number: number,
      external_reference: booked.external_reference
    }

    state =
      state
      |> Map.update!(:drafts, &Map.delete(&1, draft_id))
      |> Map.update!(:booked, &Map.put(&1, number, booked))
      |> Map.update!(:by_reference, &Map.put(&1, booked.external_reference, {:booked, number}))
      |> Map.put(:next_booked_number, state.next_booked_number + 1)
      |> Map.update!(:webhook_events, &Map.put(&1, number, event))

    state = if deliver_webhook?, do: deliver_webhook(state, event), else: state

    {{:ok, booked}, state}
  end

  # get_document is strict per ref type: a booked document is not retrievable
  # as {:draft, id} (the draft is gone after booking — SPEC §17.9 step 2
  # requires callers to search booked invoices by external reference).
  defp do_get_document(state, {:draft, id} = ref) do
    case Map.fetch(state.drafts, id) do
      {:ok, doc} -> {:ok, doc}
      :error -> {:error, {:not_found, ref}}
    end
  end

  defp do_get_document(state, {:booked, number} = ref) do
    case Map.fetch(state.booked, number) do
      {:ok, doc} -> {:ok, doc}
      :error -> {:error, {:not_found, ref}}
    end
  end

  defp do_get_document(state, {:external_reference, _} = ref) do
    case resolve_ref(state, ref) do
      {_kind, _id, doc} -> {:ok, doc}
      :not_found -> {:error, {:not_found, ref}}
    end
  end

  defp resolve_ref(state, {:draft, id}) do
    case Map.fetch(state.drafts, id) do
      {:ok, doc} ->
        {:draft, id, doc}

      :error ->
        case Enum.find(state.booked, fn {_number, doc} -> doc.external_draft_id == id end) do
          {number, doc} -> {:booked, number, doc}
          nil -> :not_found
        end
    end
  end

  defp resolve_ref(state, {:booked, number}) do
    case Map.fetch(state.booked, number) do
      {:ok, doc} -> {:booked, number, doc}
      :error -> :not_found
    end
  end

  defp resolve_ref(state, {:external_reference, ref}) do
    case Map.fetch(state.by_reference, ref) do
      {:ok, target} -> resolve_ref(state, target)
      :error -> :not_found
    end
  end

  defp reindex_reference(state, old_ref, new_ref, _target) when old_ref == new_ref, do: state

  defp reindex_reference(state, old_ref, new_ref, target) do
    Map.update!(state, :by_reference, fn refs ->
      refs |> Map.delete(old_ref) |> Map.put(new_ref, target)
    end)
  end

  ## Normalization

  defp normalize_draft(%CanonicalInvoice{} = invoice, draft_id) do
    recipient_fingerprint = Fingerprint.recipient(invoice.recipient)

    doc = %Document{
      state: :draft,
      external_draft_id: draft_id,
      external_reference: invoice.external_reference,
      customer_external_id: invoice.customer_external_id,
      customer_snapshot_fingerprint:
        Canonical.hash(%{
          customer_external_id: invoice.customer_external_id,
          recipient_fingerprint: recipient_fingerprint
        }),
      recipient_fingerprint: recipient_fingerprint,
      invoice_date: invoice.invoice_date,
      currency: invoice.currency,
      payment_term_external_id: invoice.payment_term_external_id,
      layout_external_id: invoice.layout_external_id,
      lines: Enum.map(invoice.lines, &normalize_line/1),
      provider_extras: %{
        document_type: invoice.document_type,
        delivery_mode: invoice.delivery_mode
      }
    }

    %{doc | external_hash: content_hash(doc)}
  end

  defp normalize_line(%Line{} = line) do
    %{
      order: line.order,
      product_external_id: line.product_external_id,
      amount: line.amount,
      description: Fingerprint.normalize_text(line.description),
      description_fingerprint: Fingerprint.description(line.description),
      recognition: normalize_recognition(line.recognition)
    }
  end

  defp normalize_recognition(:point_in_time), do: :point_in_time

  defp normalize_recognition({:over_time, %Period{} = period}),
    do: {:over_time, period.start_date, period.end_date_exclusive}

  defp refresh_line_fingerprint(%{description: description} = line) when is_binary(description) do
    %{line | description_fingerprint: Fingerprint.description(description)}
  end

  defp refresh_line_fingerprint(line), do: line

  # Deterministic hash over the document's normalized content. Any human edit
  # to amounts, descriptions, header fields, or recipient identity changes it.
  defp content_hash(%Document{} = doc) do
    Canonical.hash(%{
      state: doc.state,
      external_reference: doc.external_reference,
      external_booked_number: doc.external_booked_number,
      customer_external_id: doc.customer_external_id,
      recipient_fingerprint: doc.recipient_fingerprint,
      invoice_date: doc.invoice_date,
      currency: doc.currency,
      payment_term_external_id: doc.payment_term_external_id,
      layout_external_id: doc.layout_external_id,
      lines:
        Enum.map(doc.lines, fn line ->
          %{
            order: line.order,
            product_external_id: line.product_external_id,
            amount: line.amount,
            description_fingerprint: line.description_fingerprint,
            recognition: hashable_recognition(line.recognition)
          }
        end)
    })
  end

  defp hashable_recognition(:point_in_time), do: %{kind: :point_in_time}

  defp hashable_recognition({:over_time, start_date, end_exclusive}),
    do: %{kind: :over_time, start: start_date, end_exclusive: end_exclusive}

  defp deliver_webhook(state, event) do
    if sink = state.webhook_sink, do: sink.(event)
    state
  end
end
