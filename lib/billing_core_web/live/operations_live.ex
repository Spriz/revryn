defmodule BillingCoreWeb.OperationsLive do
  @moduledoc """
  Failure inbox (SPEC §22.9.3): actionable durable operations with safe
  remediation actions, distinguishing "automatic retry pending" from
  "action required", plus a recent-operations feed.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Operations
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

          <%!-- SPEC BC-US-156: whether retry is safe, stated explicitly. --%>
          <p
            :if={attention(operation) == :action_required}
            id={"safety-#{operation.id}"}
            class="mt-2 text-sm"
          >
            {retry_safety(operation)}
          </p>

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
              :if={
                remediation_kind(operation) == :user_fixable and operation.state == "failed" and
                  erp_operation?(operation)
              }
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

          <%!-- BC-US-156: copyable support bundle when self-service is
               limited, with precise next-step guidance. --%>
          <div :if={attention(operation) == :action_required} class="mt-3">
            <p id={"guidance-#{operation.id}"} class="text-xs opacity-70">
              {guidance(operation)}
            </p>
            <input
              id={"bundle-#{operation.id}"}
              type="text"
              readonly
              phx-hook=".SelectOnClick"
              value={support_bundle(operation)}
              class="mt-1 w-full rounded border border-base-300 bg-base-200 px-2 py-1 font-mono text-xs"
            />
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectOnClick">
          export default {
            mounted() {
              this.el.addEventListener("click", () => this.el.select());
            }
          }
        </script>
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

  @refresh_interval 4_000

  def mount(_params, _session, socket) do
    # In-flight operations settle asynchronously; the inbox re-derives on a
    # short timer so arriving failures and automatic recoveries show up
    # without a manual reload (SPEC §22.9.3).
    if connected?(socket) do
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok, socket |> assign(page_title: "Operations") |> refresh()}
  end

  def handle_info(:refresh, socket) do
    {:noreply, refresh(socket)}
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
    # Authorization (operator-only vs finance) and requeueing live in the
    # domain command — this surface stays a thin adapter (SPEC §12.5).
    with {:ok, operation} <- fetch_team_operation(socket, id),
         {:ok, _requeued} <- Sync.remediate_operation(socket.assigns.scope, operation) do
      {:noreply, socket |> put_flash(:info, "Operation requeued after remediation.") |> refresh()}
    else
      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, LiveHelpers.error_message(reason)) |> refresh()}
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
      :automatic ->
        "automatic"

      :action_required ->
        case remediation_kind(operation) do
          :user_fixable -> "action required — user-fixable"
          :operator_only -> "action required — operator-only"
          :non_retryable -> "action required — non-retryable"
          :automatic -> "action required"
        end
    end
  end

  # BC-US-156: the remediation taxonomy behind the action-required states.
  defp remediation_kind(%{state: "blocked", error_class: "authorization"}), do: :operator_only
  defp remediation_kind(%{state: "blocked"}), do: :user_fixable

  defp remediation_kind(%{state: "failed", error_class: class})
       when class in ["terminal", "poison"],
       do: :non_retryable

  defp remediation_kind(%{state: "failed"}), do: :user_fixable
  defp remediation_kind(_operation), do: :automatic

  defp retry_safety(operation) do
    case remediation_kind(operation) do
      :user_fixable ->
        "Retry is safe: it reuses the same operation key, so no duplicate external effect can occur. Correct the underlying data first."

      :operator_only ->
        "Retry alone will not help: the provider rejected our authority. A team admin must revalidate the ERP connection, then requeue."

      :non_retryable ->
        "Not retryable from this inbox: the provider cannot accept this request in any retry. Escalate with the support bundle below."

      :automatic ->
        "No action needed — the retry policy is handling this."
    end
  end

  defp guidance(operation) do
    case remediation_kind(operation) do
      :user_fixable ->
        "Fix the cause shown above, then press Retry. If it fails again with the same code, share this bundle with support:"

      :operator_only ->
        "Ask a team admin to revalidate the ERP connection under Settings, then requeue here. Share this bundle if the provider keeps rejecting:"

      :non_retryable ->
        "Escalate to support with this bundle — it identifies the exact operation and audit trail without exposing any payload:"

      :automatic ->
        "Reference for support:"
    end
  end

  defp support_bundle(operation) do
    "revryn-support operation=#{operation.id} type=#{operation.type} " <>
      "code=#{operation.safe_error_code || operation.error_class || "unknown"} " <>
      "correlation=#{operation.correlation_id || "none"}"
  end
end
