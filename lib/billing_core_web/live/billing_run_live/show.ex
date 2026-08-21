defmodule BillingCoreWeb.BillingRunLive.Show do
  @moduledoc """
  Billing-run dashboard detail (BC-US-115/116): the run's invoice intents
  grouped by lifecycle bucket, each with its next action, plus run closing.
  Bulk approval is deliberately absent — approval is per invoice after
  individual validation and reconciliation.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Billing
  alias BillingCoreWeb.LiveHelpers

  @buckets [
    {:ready, "Ready", ~w(frozen)},
    {:blocked, "Blocked", ~w(credit_required)},
    {:syncing, "Syncing", ~w(sync_pending booking_pending)},
    {:awaiting_approval, "Awaiting approval", ~w(erp_draft approved)},
    {:booked, "Booked", ~w(erp_booked)},
    {:failed, "Failed", ~w(sync_error)}
  ]

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:billing_runs} />

      <.header>
        Run {@run.invoice_date}
        <:subtitle>
          <span class="font-mono text-xs">{@run.run_key}</span>
          <.state_badge state={@run.status} class="ml-1" />
          · engine v{@run.engine_version} · usage cutoff {format_dt(@run.usage_cutoff)}
        </:subtitle>
        <:actions>
          <.button
            :if={@run.status == "open"}
            id="close-run-button"
            phx-click="close_run"
            phx-disable-with="Closing…"
            data-confirm="Close this run? Closed runs accept no new invoice intent."
          >
            Close run
          </.button>
        </:actions>
      </.header>

      <div class="space-y-6">
        <section
          :for={{key, label, _states} <- buckets()}
          id={"bucket-#{key}"}
          class="rounded-lg border border-base-300 p-4"
        >
          <h2 class="flex items-center gap-2 font-semibold">
            {label}
            <span class="badge badge-sm badge-ghost tabular-nums">
              {length(Map.get(@grouped, key, []))}
            </span>
          </h2>

          <p :if={Map.get(@grouped, key, []) == []} class="mt-1 text-sm opacity-50">None.</p>

          <table :if={Map.get(@grouped, key, []) != []} class="mt-2 table table-sm">
            <thead>
              <tr>
                <th>Customer</th>
                <th>Kind</th>
                <th class="text-right">Net</th>
                <th>State</th>
                <th>Next action</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={%{intent: intent, state: state} <- Map.get(@grouped, key, [])}
                id={"run-intent-#{intent.id}"}
              >
                <td>
                  <.link navigate={~p"/teams/#{@team.id}/invoices/#{intent.id}"} class="link">
                    {customer_label(intent)}
                  </.link>
                </td>
                <td>{intent.document_kind}</td>
                <td class="text-right">
                  <.money currency={intent.currency} minor={intent.net_amount_minor} />
                </td>
                <td><.state_badge state={state} /></td>
                <td class="text-sm opacity-80">{next_action(state)}</td>
              </tr>
            </tbody>
          </table>
        </section>

        <section :if={@other != []} class="rounded-lg border border-base-300 p-4" id="bucket-other">
          <h2 class="font-semibold">Superseded</h2>
          <ul class="mt-1 space-y-1 text-sm">
            <li :for={%{intent: intent, state: state} <- @other}>
              <.link navigate={~p"/teams/#{@team.id}/invoices/#{intent.id}"} class="link">
                {customer_label(intent)}
              </.link>
              <.state_badge state={state} class="ml-1" />
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"id" => id}, _session, socket) do
    case Billing.get_run(socket.assigns.scope, id) do
      {:ok, run} ->
        {:ok, socket |> assign(run: run, page_title: "Run #{run.invoice_date}") |> load_intents()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Billing run not found.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/billing-runs")}
    end
  end

  def handle_event("close_run", _params, socket) do
    case Billing.close_run(socket.assigns.scope, socket.assigns.run) do
      {:ok, run} ->
        {:noreply,
         socket |> put_flash(:info, "Run closed.") |> assign(run: run) |> load_intents()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp load_intents(socket) do
    {:ok, entries} = Billing.list_run_intents(socket.assigns.scope, socket.assigns.run)

    grouped =
      Enum.group_by(entries, fn %{state: state} ->
        Enum.find_value(@buckets, :other, fn {key, _label, states} ->
          if state in states, do: key
        end)
      end)

    assign(socket,
      grouped: Map.drop(grouped, [:other]),
      other: Map.get(grouped, :other, [])
    )
  end

  defp buckets, do: @buckets

  defp customer_label(intent) do
    get_in(intent.canonical_snapshot, ["customer", "legalName"]) ||
      get_in(intent.canonical_snapshot, ["customer", "externalId"]) ||
      intent.customer_id
  end

  defp next_action("frozen"), do: "Synchronize to the ERP"
  defp next_action("sync_pending"), do: "Draft creation in progress — automatic"
  defp next_action("erp_draft"), do: "Review the reconciled draft and approve"
  defp next_action("approved"), do: "Book the approved draft"
  defp next_action("booking_pending"), do: "Booking in progress — automatic"
  defp next_action("erp_booked"), do: "None — booked"
  defp next_action("sync_error"), do: "Investigate in the operations inbox"
  defp next_action("credit_required"), do: "Complete the correction case"
  defp next_action(_state), do: "—"
end
