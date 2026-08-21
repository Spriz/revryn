defmodule BillingCoreWeb.BillingRunLive.Index do
  @moduledoc """
  Billing runs: listing plus "process the regular run for a date"
  (BC-US-115, SPEC §18).
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Billing
  alias BillingCore.Billing.Scheduler
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:billing_runs} />

      <.header>
        Billing runs
        <:subtitle>One run per date and policy; charges consolidate per customer.</:subtitle>
      </.header>

      <div class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">Process regular run</h2>
        <.form for={@run_form} id="process-run-form" phx-submit="process_run">
          <div class="flex items-end gap-2">
            <.input field={@run_form[:invoice_date]} type="date" label="Invoice date" required />
            <.button variant="primary" phx-disable-with="Processing…">Process run</.button>
          </div>
        </.form>
        <p class="mt-1 text-xs opacity-60">
          Idempotent: re-processing a date reuses the existing run and never double-bills an
          occurrence (SPEC §18.4).
        </p>
      </div>

      <.empty_state :if={@runs == []} id="no-runs">
        No billing runs yet — process one for a date above.
      </.empty_state>

      <.table
        :if={@runs != []}
        id="billing-runs"
        rows={@runs}
        row_click={fn run -> JS.navigate(~p"/teams/#{@team.id}/billing-runs/#{run.id}") end}
      >
        <:col :let={run} label="Invoice date">
          <span class="font-medium tabular-nums">{run.invoice_date}</span>
        </:col>
        <:col :let={run} label="Run key"><span class="font-mono text-xs">{run.run_key}</span></:col>
        <:col :let={run} label="Status"><.state_badge state={run.status} /></:col>
        <:col :let={run} label="Started">{format_dt(run.started_at)}</:col>
        <:col :let={run} label="Closed">{format_dt(run.closed_at) || "—"}</:col>
        <:action :let={run}>
          <.link navigate={~p"/teams/#{@team.id}/billing-runs/#{run.id}"} class="link">View</.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Billing runs",
       run_form: to_form(%{"invoice_date" => Date.to_iso8601(Date.utc_today())}, as: "run")
     )
     |> load_runs()}
  end

  def handle_event("process_run", %{"run" => %{"invoice_date" => date_param}}, socket) do
    with {:ok, date} <- LiveHelpers.parse_date(date_param),
         {:ok, %{run: run, invoiced: invoiced, skipped: skipped}} <-
           Scheduler.process_regular_run(socket.assigns.scope, date) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Run #{run.run_key}: #{length(invoiced)} invoice(s) frozen, " <>
           "#{map_size(skipped)} subscription(s) skipped."
       )
       |> load_runs()}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Enter a valid invoice date.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp load_runs(socket) do
    {:ok, runs} = Billing.list_runs(socket.assigns.scope)
    assign(socket, :runs, runs)
  end
end
