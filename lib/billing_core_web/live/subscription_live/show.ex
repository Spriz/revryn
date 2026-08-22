defmodule BillingCoreWeb.SubscriptionLive.Show do
  @moduledoc """
  Subscription detail: version timeline and change history (BC-US-036…039),
  lifecycle actions, and the invoice preview → freeze flow (BC-US-068/069).
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Billing.Preview
  alias BillingCore.Contracts
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:subscriptions} />

      <.header>
        {@subscription.external_id}
        <:subtitle>
          <.state_badge state={@subscription.status} />
          <span class="ml-1">
            {@subscription.start_date} → {@subscription.end_date_exclusive || "∞"} · v{@subscription.current_version}
          </span>
        </:subtitle>
      </.header>

      <div class="grid gap-6 lg:grid-cols-2">
        <section class="space-y-6">
          <div class="rounded-lg border border-base-300 p-4" id="subscription-actions">
            <h2 class="mb-3 font-semibold">Actions</h2>

            <.form
              :if={@subscription.status == :active}
              for={@quantity_form}
              id="change-quantity-form"
              phx-submit="change_quantity"
            >
              <div class="flex items-end gap-2">
                <.input
                  field={@quantity_form[:quantity]}
                  type="number"
                  label="New quantity"
                  min="0"
                  step="any"
                  required
                />
                <.input
                  field={@quantity_form[:effective_date]}
                  type="date"
                  label="Effective (today if empty)"
                />
                <.button phx-disable-with="Applying…">Change quantity</.button>
              </div>
            </.form>

            <div class="mt-3 flex gap-2">
              <.button
                :if={@subscription.status == :active}
                id="pause-subscription"
                phx-click="pause"
                phx-disable-with="Pausing…"
                data-confirm="Pause this subscription?"
              >
                Pause
              </.button>
              <.button
                :if={@subscription.status == :paused}
                id="resume-subscription"
                variant="primary"
                phx-click="resume"
                phx-disable-with="Resuming…"
              >
                Resume
              </.button>
            </div>

            <.form
              :if={@subscription.status in [:active, :scheduled]}
              for={@cancel_form}
              id="cancel-form"
              phx-change="cancel_form_changed"
              phx-submit="cancel"
              class="mt-4 border-t border-base-200 pt-3"
            >
              <div class="grid gap-x-4 sm:grid-cols-2">
                <.input
                  field={@cancel_form[:mode]}
                  type="select"
                  label="Cancellation mode"
                  options={[{"End of period", "end_of_period"}, {"Immediate", "immediate"}]}
                />
                <.input
                  :if={@cancel_mode == "end_of_period"}
                  field={@cancel_form[:period_end_date]}
                  type="date"
                  label="Period end date"
                  required
                />
                <.input
                  :if={@cancel_mode == "immediate"}
                  field={@cancel_form[:effective_date]}
                  type="date"
                  label="Effective (today if empty)"
                />
                <.input field={@cancel_form[:reason]} type="text" label="Reason" />
              </div>
              <.button
                class="mt-2"
                phx-disable-with="Cancelling…"
                data-confirm="Cancel this subscription?"
              >
                Cancel subscription
              </.button>
            </.form>
          </div>

          <div class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Versions</h2>
            <table class="table table-sm" id="subscription-versions">
              <thead>
                <tr>
                  <th>Version</th>
                  <th>Quantity</th>
                  <th>Effective</th>
                  <th>Policy</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={version <- @versions} id={"subscription-version-#{version.version}"}>
                  <td>v{version.version}</td>
                  <td class="tabular-nums">{version.quantity}</td>
                  <td>
                    <.period
                      start={version.effective_start}
                      end_exclusive={version.effective_end_exclusive || "∞"}
                    />
                  </td>
                  <td>{version.cancellation_policy}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Change history</h2>
            <table class="table table-sm" id="subscription-changes">
              <thead>
                <tr>
                  <th>Change</th>
                  <th>Effective</th>
                  <th>Recorded</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={change <- @changes} id={"subscription-change-#{change.id}"}>
                  <td>{change.change_type}</td>
                  <td>{change.effective_date}</td>
                  <td>{format_dt(change.created_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="space-y-6">
          <div class="rounded-lg border border-base-300 p-4" id="preview-panel">
            <h2 class="mb-2 font-semibold">Invoice preview</h2>
            <p class="mb-3 text-sm opacity-70">
              Rates the billing period containing the chosen date (BC-US-068). Estimated VAT
              is not included — VAT is authoritative only in the ERP.
            </p>

            <.form for={@preview_form} id="preview-form" phx-submit="preview">
              <div class="flex items-end gap-2">
                <.input field={@preview_form[:date]} type="date" label="Invoice date" required />
                <.button variant="primary" phx-disable-with="Rating…">Preview</.button>
              </div>
            </.form>

            <div :if={@preview} class="mt-4 space-y-3" id="preview-result">
              <div
                :if={@preview.blockers != []}
                id="preview-blockers"
                class="rounded border border-error/40 bg-error/10 p-3 text-sm"
              >
                <p class="font-semibold text-error">Blockers</p>
                <ul class="mt-1 list-inside list-disc">
                  <li :for={blocker <- @preview.blockers}>{inspect(blocker)}</li>
                </ul>
              </div>

              <table class="table table-sm" id="preview-lines">
                <thead>
                  <tr>
                    <th>Description</th>
                    <th>Service period</th>
                    <th class="text-right">Qty</th>
                    <th class="text-right">Amount</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{line, index} <- Enum.with_index(@preview.lines)}>
                    <td>
                      {line.description}
                      <.trace id={"preview-line-#{index}-trace"} trace={line.calculation_trace} />
                    </td>
                    <td>
                      <.period start={line.service_start} end_exclusive={line.service_end_exclusive} />
                    </td>
                    <td class="text-right tabular-nums">{line.quantity}</td>
                    <td class="text-right">
                      <.money currency={@preview.currency} minor={line.amount_minor} />
                    </td>
                  </tr>
                </tbody>
              </table>

              <dl class="ml-auto w-64 space-y-1 text-sm" id="preview-totals">
                <div class="flex justify-between">
                  <dt class="opacity-70">Net total</dt>
                  <dd><.money currency={@preview.currency} minor={@preview.net_amount_minor} /></dd>
                </div>
                <div class="flex justify-between">
                  <dt class="opacity-70">Credit applied</dt>
                  <dd>
                    <.money currency={@preview.currency} minor={-@preview.credit_planned_minor} />
                  </dd>
                </div>
                <div class="flex justify-between border-t border-base-300 pt-1 font-semibold">
                  <dt>Amount due</dt>
                  <dd><.money currency={@preview.currency} minor={@preview.amount_due_minor} /></dd>
                </div>
              </dl>

              <div class="flex items-center justify-between">
                <span class="text-xs opacity-60">
                  Fingerprint <.hash value={@preview.fingerprint} />
                </span>
                <.button
                  :if={@preview.blockers == []}
                  id="freeze-button"
                  variant="primary"
                  phx-click="freeze"
                  phx-disable-with="Freezing…"
                  data-confirm="Freeze this preview into immutable invoice intent?"
                >
                  Freeze invoice intent
                </.button>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"id" => id}, _session, socket) do
    case Contracts.get_subscription(socket.assigns.scope, id) do
      {:ok, subscription} ->
        {:ok,
         socket
         |> assign(
           subscription: subscription,
           preview: nil,
           cancel_mode: "end_of_period",
           preview_form: to_form(%{"date" => Date.to_iso8601(Date.utc_today())}, as: "preview"),
           quantity_form: to_form(%{}, as: "quantity"),
           cancel_form: to_form(%{"mode" => "end_of_period"}, as: "cancel")
         )
         |> refresh()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Subscription not found.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/subscriptions")}
    end
  end

  def handle_event("change_quantity", %{"quantity" => params}, socket) do
    case LiveHelpers.parse_decimal(params["quantity"]) do
      :error ->
        {:noreply, put_flash(socket, :error, "Enter a valid quantity.")}

      {:ok, quantity} ->
        attrs =
          case LiveHelpers.parse_date(params["effective_date"]) do
            {:ok, date} -> %{quantity: quantity, effective_date: date}
            :error -> %{quantity: quantity}
          end

        case Contracts.change_quantity(socket.assigns.scope, socket.assigns.subscription, attrs) do
          {:ok, subscription} ->
            {:noreply,
             socket
             |> put_flash(:info, "Quantity changed.")
             |> assign(subscription: subscription, preview: nil)
             |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
        end
    end
  end

  def handle_event("pause", _params, socket) do
    lifecycle_action(socket, &Contracts.pause_subscription/3, %{}, "Subscription paused.")
  end

  def handle_event("resume", _params, socket) do
    lifecycle_action(socket, &Contracts.resume_subscription/3, %{}, "Subscription resumed.")
  end

  def handle_event("cancel_form_changed", %{"cancel" => params}, socket) do
    {:noreply,
     assign(socket,
       cancel_mode: params["mode"] || "end_of_period",
       cancel_form: to_form(params, as: "cancel")
     )}
  end

  def handle_event("cancel", %{"cancel" => params}, socket) do
    attrs = %{
      mode: String.to_existing_atom(params["mode"] || "end_of_period"),
      reason: params["reason"]
    }

    attrs =
      case {params["mode"], LiveHelpers.parse_date(params["period_end_date"]),
            LiveHelpers.parse_date(params["effective_date"])} do
        {"end_of_period", {:ok, period_end}, _} -> Map.put(attrs, :period_end_date, period_end)
        {"immediate", _, {:ok, effective}} -> Map.put(attrs, :effective_date, effective)
        _other -> attrs
      end

    lifecycle_action(socket, &Contracts.cancel_subscription/3, attrs, "Cancellation recorded.")
  end

  def handle_event("preview", %{"preview" => %{"date" => date_param}}, socket) do
    with {:ok, date} <- LiveHelpers.parse_date(date_param),
         {:ok, preview} <-
           Preview.for_subscription(socket.assigns.scope, socket.assigns.subscription.id, date) do
      {:noreply,
       assign(socket,
         preview: preview,
         preview_form: to_form(%{"date" => date_param}, as: "preview")
       )}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Enter a valid invoice date.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(preview: nil)
         |> put_flash(:error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("freeze", _params, socket) do
    case socket.assigns.preview do
      nil ->
        {:noreply, put_flash(socket, :error, "Build a preview first.")}

      preview ->
        case Preview.freeze(socket.assigns.scope, preview) do
          {:ok, intent} ->
            {:noreply,
             socket
             |> put_flash(:info, "Invoice intent frozen.")
             |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/invoices/#{intent.id}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(preview: nil)
             |> put_flash(:error, LiveHelpers.error_message(reason))}
        end
    end
  end

  defp lifecycle_action(socket, fun, attrs, success_message) do
    case fun.(socket.assigns.scope, socket.assigns.subscription, attrs) do
      {:ok, subscription} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> assign(subscription: subscription, preview: nil)
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp refresh(socket) do
    scope = socket.assigns.scope
    subscription = socket.assigns.subscription

    {:ok, versions} = Contracts.list_subscription_versions(scope, subscription)
    {:ok, changes} = Contracts.list_subscription_changes(scope, subscription)

    assign(socket,
      page_title: subscription.external_id,
      versions: versions,
      changes: changes
    )
  end
end
