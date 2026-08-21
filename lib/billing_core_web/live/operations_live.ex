defmodule BillingCoreWeb.OperationsLive do
  @moduledoc """
  Failure inbox (SPEC §22.9.3): actionable durable operations with safe
  remediation actions, distinguishing "automatic retry pending" from
  "action required", plus a recent-operations feed.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.{Operations, Scope}
  alias BillingCore.ERP.Sync
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:operations} />

      <.header>
        Operations
        <:subtitle>
          Remediation inbox for durable operations — not a generic job monitor.
        </:subtitle>
      </.header>

      <section class="space-y-4">
        <h2 class="text-lg font-semibold">Failure inbox</h2>

        <.empty_state :if={@inbox == []} id="empty-inbox">
          Nothing needs attention. Failed and blocked operations appear here.
        </.empty_state>

        <div
          :for={operation <- @inbox}
          id={"operation-#{operation.id}"}
          class="rounded-lg border border-base-300 p-4"
        >
          <div class="flex flex-wrap items-center gap-2">
            <.state_badge state={operation.state} />
            <span class="font-mono text-sm font-medium">{operation.type}</span>
            <span class={[
              "badge badge-sm",
              if(attention(operation) == :action_required, do: "badge-error", else: "badge-warning")
            ]}>
              {attention_label(operation)}
            </span>
          </div>

          <dl class="mt-2 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
            <div :if={operation.error_class} class="flex gap-2">
              <dt class="opacity-60">Error</dt>
              <dd>
                {operation.error_class}
                <span :if={operation.safe_error_code} class="font-mono">
                  ({operation.safe_error_code})
                </span>
              </dd>
            </div>
            <div :if={operation.safe_error_summary} class="flex gap-2">
              <dt class="opacity-60">Summary</dt>
              <dd>{operation.safe_error_summary}</dd>
            </div>
            <div :if={operation.blocked_reason} class="flex gap-2">
              <dt class="opacity-60">Blocked</dt>
              <dd>{operation.blocked_reason}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="opacity-60">Attempts</dt>
              <dd class="tabular-nums">{operation.attempt_count}</dd>
            </div>
            <div :if={operation.next_attempt_at} class="flex gap-2">
              <dt class="opacity-60">Next attempt</dt>
              <dd>{format_dt(operation.next_attempt_at)}</dd>
            </div>
            <div :if={operation.correlation_id} class="flex gap-2">
              <dt class="opacity-60">Correlation</dt>
              <dd class="font-mono text-xs">{operation.correlation_id}</dd>
            </div>
            <div :if={operation.target_type} class="flex gap-2">
              <dt class="opacity-60">Target</dt>
              <dd>
                <.link
                  :if={operation.target_type == "invoice_intent"}
                  navigate={~p"/teams/#{@team.id}/invoices/#{operation.target_id}"}
                  class="link"
                >
                  invoice intent
                </.link>
                <span :if={operation.target_type != "invoice_intent"}>
                  {operation.target_type}
                </span>
              </dd>
            </div>
          </dl>

          <div class="mt-3 flex gap-2">
            <.button
              :if={operation.state == "failed" and erp_operation?(operation)}
              id={"retry-#{operation.id}"}
              variant="primary"
              phx-click="retry"
              phx-value-id={operation.id}
              phx-disable-with="Retrying…"
            >
              Retry
            </.button>
            <.button
              :if={operation.state == "blocked"}
              id={"remediate-#{operation.id}"}
              phx-click="remediate"
              phx-value-id={operation.id}
              phx-disable-with="Requeuing…"
              data-confirm="Requeue this operation? Fix the underlying precondition first."
            >
              Remediate &amp; requeue
            </.button>
          </div>
        </div>
      </section>

      <section class="mt-10 space-y-2">
        <h2 class="text-lg font-semibold">Recent operations</h2>
        <p :if={@recent == []} class="text-sm opacity-70">No operations recorded yet.</p>
        <table :if={@recent != []} class="table table-sm" id="recent-operations">
          <thead>
            <tr>
              <th>Type</th>
              <th>State</th>
              <th>Attempts</th>
              <th>Started</th>
              <th>Finished</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={operation <- @recent} id={"recent-operation-#{operation.id}"}>
              <td class="font-mono text-sm">{operation.type}</td>
              <td><.state_badge state={operation.state} /></td>
              <td class="tabular-nums">{operation.attempt_count}</td>
              <td>{format_dt(operation.started_at) || "—"}</td>
              <td>{format_dt(operation.finished_at) || "—"}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Operations") |> refresh()}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    with {:ok, operation} <- fetch_team_operation(socket, id),
         {:ok, _retried} <- Sync.retry_operation(socket.assigns.scope, operation) do
      {:noreply, socket |> put_flash(:info, "Operation requeued for retry.") |> refresh()}
    else
      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  def handle_event("remediate", %{"id" => id}, socket) do
    scope = socket.assigns.scope

    with :ok <- authorize_remediate(scope),
         {:ok, operation} <- fetch_team_operation(socket, id),
         {:ok, _requeued} <- Operations.transition(operation, :remediate) do
      {:noreply, socket |> put_flash(:info, "Operation requeued after remediation.") |> refresh()}
    else
      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
    end
  end

  defp authorize_remediate(scope) do
    if Scope.has_team_role?(scope, [:finance_operator, :team_admin]) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp fetch_team_operation(socket, id) do
    operation = Operations.get!(id)

    if operation.team_id == socket.assigns.team.id do
      {:ok, operation}
    else
      {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :not_found}
  end

  defp refresh(socket) do
    team_id = socket.assigns.team.id

    assign(socket,
      inbox: Operations.failure_inbox(team_id),
      recent: Operations.list_recent(team_id)
    )
  end

  defp erp_operation?(%{type: "erp." <> _rest}), do: true
  defp erp_operation?(_operation), do: false

  # SPEC §22.9.3: distinguish "automatic retry pending" from "action required".
  defp attention(%{state: state}) when state in ["blocked", "failed"], do: :action_required
  defp attention(_operation), do: :automatic

  defp attention_label(%{state: "outcome_unknown"}), do: "automatic reconciliation pending"
  defp attention_label(%{state: "reconciling"}), do: "reconciling — automatic"
  defp attention_label(%{state: "retry_scheduled"}), do: "automatic retry pending"

  defp attention_label(operation) do
    case attention(operation) do
      :action_required -> "action required"
      :automatic -> "automatic"
    end
  end
end
