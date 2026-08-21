defmodule BillingCoreWeb.IntentLive do
  @moduledoc """
  Invoice-intent detail: the immutable snapshot with per-line calculation
  traces (BC-US-110), lifecycle history, the mirrored ERP document, and the
  state-dependent workflow actions — synchronize (BC-US-081), approve
  (BC-US-084), book (BC-US-085), supersede (BC-US-100), and corrections
  (BC-US-102/103).

  Subscribes to the team's domain-event topic and refreshes when the intent
  or its ERP document changes.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Billing
  alias BillingCore.Billing.{Corrections, Preview}
  alias BillingCore.Contracts
  alias BillingCore.ERP
  alias BillingCore.ERP.Sync
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:billing_runs} />

      <.header>
        {customer_label(@intent)}
        <:subtitle>
          {@intent.document_kind} · {@intent.invoice_date} · {@intent.currency} · intent v{@intent.intent_version}
          <.state_badge state={@state} class="ml-1" id="intent-state-badge" />
        </:subtitle>
        <:actions>
          <div class="flex flex-wrap gap-2" id="intent-actions">
            <.button
              :if={@state == "frozen"}
              id="synchronize-button"
              variant="primary"
              phx-click="synchronize"
              phx-disable-with="Requesting…"
            >
              Synchronize to ERP
            </.button>
            <.button
              :if={@state == "frozen" && @rebuild_subscription}
              id="supersede-button"
              phx-click="supersede"
              phx-disable-with="Rebuilding…"
              data-confirm="Supersede this intent with a freshly rated preview?"
            >
              Supersede with fresh preview
            </.button>
            <.button
              :if={@state == "approved"}
              id="book-button"
              variant="primary"
              phx-click="book"
              phx-disable-with="Requesting…"
              data-confirm="Book this invoice in the ERP? Booked documents are immutable."
            >
              Book
            </.button>
          </div>
        </:actions>
      </.header>

      <p class="text-sm opacity-70">
        Content hash <.hash value={@intent.content_hash} /> · net
        <.money currency={@intent.currency} minor={@intent.net_amount_minor} />
        <span :if={@intent.billing_run_id}>
          ·
          <.link
            navigate={~p"/teams/#{@team.id}/billing-runs/#{@intent.billing_run_id}"}
            class="link"
          >
            billing run
          </.link>
        </span>
      </p>

      <div class="mt-4 grid gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-2">
          <section class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Lines</h2>
            <table class="table table-sm" id="intent-lines">
              <thead>
                <tr>
                  <th>Description</th>
                  <th>Service period</th>
                  <th class="text-right">Qty</th>
                  <th class="text-right">Amount</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={line <- @intent.lines} id={"line-#{line.id}"}>
                  <td>
                    {line.description}
                    <.trace id={"line-#{line.id}-trace"} trace={line.calculation_trace} />
                  </td>
                  <td>
                    <.period start={line.service_start} end_exclusive={line.service_end_exclusive} />
                  </td>
                  <td class="text-right tabular-nums">{line.quantity}</td>
                  <td class="text-right">
                    <.money currency={line.currency} minor={line.amount_minor} />
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <section :if={@state == "erp_draft"} class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Approve for booking</h2>
            <p class="mb-2 text-sm opacity-70">
              Approval records the intent hash and the reconciled external draft hash
              (BC-US-084); any later draft change invalidates it.
            </p>
            <.form for={@approve_form} id="approve-form" phx-submit="approve">
              <div class="flex items-end gap-2">
                <.input field={@approve_form[:reason]} type="text" label="Reason" required />
                <.button variant="primary" phx-disable-with="Approving…">Approve</.button>
              </div>
            </.form>
          </section>

          <section :if={@state == "erp_booked"} class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Corrections</h2>
            <p class="mb-3 text-sm opacity-70">
              Booked invoices are immutable — corrections are compensating credit notes
              (INV-001/002).
            </p>

            <.form for={@full_credit_form} id="full-credit-form" phx-submit="full_credit">
              <div class="flex items-end gap-2">
                <.input field={@full_credit_form[:reason]} type="text" label="Reason" required />
                <.button
                  phx-disable-with="Creating…"
                  data-confirm="Credit this invoice in full?"
                >
                  Credit in full
                </.button>
              </div>
            </.form>

            <details class="mt-3">
              <summary class="cursor-pointer text-sm font-medium">Partial credit</summary>
              <.form for={@partial_credit_form} id="partial-credit-form" phx-submit="partial_credit">
                <table class="table table-sm">
                  <thead>
                    <tr>
                      <th>Line</th>
                      <th class="text-right">Original</th>
                      <th>Credit amount ({@intent.currency})</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={line <- @intent.lines}>
                      <td class="text-sm">{line.description}</td>
                      <td class="text-right">
                        <.money currency={line.currency} minor={line.amount_minor} />
                      </td>
                      <td>
                        <.input
                          type="text"
                          name={"amounts[#{line.line_key}]"}
                          id={"partial-amount-#{line.id}"}
                          value=""
                          placeholder="0.00"
                        />
                      </td>
                    </tr>
                  </tbody>
                </table>
                <.input
                  field={@partial_credit_form[:reason]}
                  type="text"
                  label="Reason"
                  required
                />
                <.button class="mt-2" phx-disable-with="Creating…">Create partial credit</.button>
              </.form>
            </details>
          </section>

          <section class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Lifecycle history</h2>
            <table class="table table-sm" id="intent-transitions">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Event</th>
                  <th>Transition</th>
                  <th>Actor</th>
                  <th>Reason</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{transition, index} <- Enum.with_index(@transitions)}
                  id={"transition-#{index}"}
                >
                  <td class="whitespace-nowrap">{format_dt(transition.occurred_at)}</td>
                  <td>{transition.event}</td>
                  <td>
                    {transition.from_state}
                    <.icon name="hero-arrow-right" class="inline size-3 opacity-50" />
                    {transition.to_state}
                  </td>
                  <td>{transition.actor_type}</td>
                  <td class="text-sm opacity-70">{transition.reason}</td>
                </tr>
              </tbody>
            </table>
          </section>
        </div>

        <div class="space-y-6">
          <section class="rounded-lg border border-base-300 p-4" id="erp-document-card">
            <h2 class="mb-2 font-semibold">ERP document</h2>
            <p :if={!@erp_document} class="text-sm opacity-70">
              Not synchronized yet.
            </p>
            <dl :if={@erp_document} class="space-y-1 text-sm">
              <div class="flex justify-between">
                <dt class="opacity-60">State</dt>
                <dd><.state_badge state={@erp_document.state} /></dd>
              </div>
              <div class="flex justify-between">
                <dt class="opacity-60">Reference</dt>
                <dd class="font-mono text-xs">{@erp_document.external_reference}</dd>
              </div>
              <div :if={@erp_document.external_draft_number} class="flex justify-between">
                <dt class="opacity-60">Draft number</dt>
                <dd class="font-mono">{@erp_document.external_draft_number}</dd>
              </div>
              <div :if={@erp_document.external_booked_number} class="flex justify-between">
                <dt class="opacity-60">Booked number</dt>
                <dd class="font-mono" id="booked-number">
                  {@erp_document.external_booked_number}
                </dd>
              </div>
              <div :if={@erp_document.last_reconciled_at} class="flex justify-between">
                <dt class="opacity-60">Last reconciled</dt>
                <dd>{format_dt(@erp_document.last_reconciled_at)}</dd>
              </div>
              <div :if={@erp_document.last_external_hash} class="flex justify-between">
                <dt class="opacity-60">External hash</dt>
                <dd><.hash value={@erp_document.last_external_hash} /></dd>
              </div>
            </dl>
            <p :if={@state == "sync_error"} class="mt-2 text-sm text-error">
              Synchronization failed — <.link
                navigate={~p"/teams/#{@team.id}/operations"}
                class="link"
              >
                review it in the operations inbox
              </.link>.
            </p>
          </section>

          <section :if={@correction_cases != []} class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Correction cases</h2>
            <ul class="space-y-2 text-sm" id="correction-cases">
              <li :for={corr <- @correction_cases}>
                <.state_badge state={corr.status} />
                <span class="ml-1">{corr.reason_code}</span>
                <.link
                  :if={corr.credit_invoice_intent_id != @intent.id}
                  navigate={~p"/teams/#{@team.id}/invoices/#{corr.credit_invoice_intent_id}"}
                  class="link ml-1"
                >
                  credit note
                </.link>
                <.link
                  :if={corr.original_invoice_intent_id != @intent.id}
                  navigate={~p"/teams/#{@team.id}/invoices/#{corr.original_invoice_intent_id}"}
                  class="link ml-1"
                >
                  original invoice
                </.link>
              </li>
            </ul>
          </section>

          <section class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Snapshot</h2>
            <dl class="space-y-1 text-sm">
              <div class="flex justify-between">
                <dt class="opacity-60">Customer</dt>
                <dd>
                  <.link
                    navigate={~p"/teams/#{@team.id}/customers/#{@intent.customer_id}"}
                    class="link"
                  >
                    {snapshot(@intent, "externalId")}
                  </.link>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="opacity-60">Customer version</dt>
                <dd>v{@intent.customer_version}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="opacity-60">Frozen at</dt>
                <dd>{format_dt(@intent.frozen_at)}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="opacity-60">Chain</dt>
                <dd class="font-mono text-xs">{String.slice(@intent.invoice_chain_id, 0, 8)}…</dd>
              </div>
              <div :if={@intent.supersedes_invoice_intent_id} class="flex justify-between">
                <dt class="opacity-60">Supersedes</dt>
                <dd>
                  <.link
                    navigate={~p"/teams/#{@team.id}/invoices/#{@intent.supersedes_invoice_intent_id}"}
                    class="link"
                  >
                    previous version
                  </.link>
                </dd>
              </div>
            </dl>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"intent_id" => intent_id}, _session, socket) do
    case Billing.get_intent(socket.assigns.scope, intent_id) do
      {:ok, intent} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(
            BillingCore.PubSub,
            "domain_events:#{socket.assigns.team.id}"
          )
        end

        {:ok,
         socket
         |> assign(
           intent: intent,
           page_title: "Invoice #{intent.invoice_date}",
           approve_form: to_form(%{}, as: "approve"),
           full_credit_form: to_form(%{}, as: "credit"),
           partial_credit_form: to_form(%{}, as: "partial")
         )
         |> refresh()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Invoice intent not found.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/billing-runs")}
    end
  end

  def handle_event("synchronize", _params, socket) do
    case Sync.request_synchronization(socket.assigns.scope, socket.assigns.intent) do
      {:ok, _operation} ->
        {:noreply, socket |> put_flash(:info, "Synchronization requested.") |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  def handle_event("approve", %{"approve" => %{"reason" => reason}}, socket) do
    case Sync.approve_invoice(socket.assigns.scope, socket.assigns.intent, reason: reason) do
      {:ok, _approval} ->
        {:noreply, socket |> put_flash(:info, "Draft approved for booking.") |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  def handle_event("book", _params, socket) do
    case Sync.request_booking(socket.assigns.scope, socket.assigns.intent) do
      {:ok, _operation} ->
        {:noreply, socket |> put_flash(:info, "Booking requested.") |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  def handle_event("supersede", _params, socket) do
    scope = socket.assigns.scope
    intent = socket.assigns.intent

    with %{} = subscription <- socket.assigns.rebuild_subscription,
         {:ok, preview} <-
           Preview.for_subscription(scope, subscription.id, intent.invoice_date),
         [] <- preview.blockers,
         {:ok, replacement} <-
           Billing.supersede_invoice_intent(scope, intent, %{
             customer_id: preview.customer_id,
             customer_version: preview.customer_version,
             customer_external_id: preview.customer_external_id,
             customer_legal_name: preview.customer_legal_name,
             contract_id: preview.contract_id,
             currency: preview.currency,
             invoice_date: preview.invoice_date,
             usage_cutoff: snapshot_cutoff(intent),
             lines: preview.lines,
             reason: "superseded_from_fresh_preview"
           }) do
      {:noreply,
       socket
       |> put_flash(:info, "Intent superseded by v#{replacement.intent_version}.")
       |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/invoices/#{replacement.id}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "This intent cannot be rebuilt from a preview.")}

      blockers when is_list(blockers) ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message({:blocked, blockers}))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  def handle_event("full_credit", %{"credit" => %{"reason" => reason}}, socket) do
    case Corrections.create_full_credit(socket.assigns.scope, socket.assigns.intent,
           reason_code: "full_credit",
           narrative: reason
         ) do
      {:ok, %{credit_intent: credit_intent}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Credit note created.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/invoices/#{credit_intent.id}")}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  def handle_event("partial_credit", params, socket) do
    intent = socket.assigns.intent
    reason = get_in(params, ["partial", "reason"])
    amounts = Map.get(params, "amounts", %{})

    case parse_allocations(amounts, intent.currency) do
      {:ok, []} ->
        {:noreply, put_flash(socket, :error, "Enter at least one credit amount.")}

      {:ok, allocations} ->
        case Corrections.create_partial_credit(socket.assigns.scope, intent, allocations,
               reason_code: "partial_credit",
               narrative: reason
             ) do
          {:ok, %{credit_intent: credit_intent}} ->
            {:noreply,
             socket
             |> put_flash(:info, "Partial credit note created.")
             |> push_navigate(
               to: ~p"/teams/#{socket.assigns.team.id}/invoices/#{credit_intent.id}"
             )}

          {:error, reason} ->
            {:noreply,
             socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
        end

      {:error, line_key} ->
        {:noreply, put_flash(socket, :error, "Invalid credit amount for line #{line_key}.")}
    end
  end

  def handle_info({:domain_event, _type, event}, socket) do
    intent_id = socket.assigns.intent.id

    relevant? =
      event.aggregate_id == intent_id or
        (is_map(event.payload) and event.payload["invoice_intent_id"] == intent_id)

    if relevant? do
      {:noreply, refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  defp refresh(socket) do
    scope = socket.assigns.scope
    {:ok, intent} = Billing.get_intent(scope, socket.assigns.intent.id)
    {:ok, transitions} = Billing.list_intent_transitions(scope, intent)

    correction_cases =
      scope
      |> Corrections.list_cases()
      |> Enum.filter(fn corr ->
        corr.original_invoice_intent_id == intent.id or
          corr.credit_invoice_intent_id == intent.id
      end)

    assign(socket,
      intent: intent,
      state: Billing.intent_state(intent),
      transitions: transitions,
      erp_document: ERP.get_document_for_intent(scope, intent.id),
      correction_cases: correction_cases,
      rebuild_subscription: rebuild_subscription(scope, intent)
    )
  end

  # Supersede-with-fresh-preview is offered only when every line traces back
  # to exactly one subscription whose preview can be rebuilt (BC-US-100 v1).
  defp rebuild_subscription(scope, intent) do
    external_ids =
      intent.lines
      |> Enum.flat_map(fn line ->
        case String.split(line.line_key, ":") do
          ["subscription", external_id | _rest] -> [external_id]
          _other -> []
        end
      end)
      |> Enum.uniq()

    with [external_id] <- external_ids,
         {:ok, subscription} <- Contracts.get_subscription_by_external_id(scope, external_id) do
      subscription
    else
      _other -> nil
    end
  end

  defp parse_allocations(amounts, currency) do
    amounts
    |> Enum.reject(fn {_line_key, value} -> String.trim(to_string(value)) == "" end)
    |> Enum.reduce_while({:ok, []}, fn {line_key, value}, {:ok, acc} ->
      case LiveHelpers.parse_major_amount(value, currency) do
        {:ok, minor} when minor > 0 -> {:cont, {:ok, acc ++ [{line_key, minor}]}}
        _other -> {:halt, {:error, line_key}}
      end
    end)
  end

  defp customer_label(intent), do: snapshot(intent, "legalName") || snapshot(intent, "externalId")

  defp snapshot(intent, key), do: get_in(intent.canonical_snapshot, ["customer", key])

  defp snapshot_cutoff(intent) do
    case intent.canonical_snapshot["usageCutoff"] do
      nil ->
        DateTime.utc_now()

      cutoff ->
        case DateTime.from_iso8601(cutoff) do
          {:ok, datetime, _offset} -> datetime
          _error -> DateTime.utc_now()
        end
    end
  end
end
