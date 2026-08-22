defmodule BillingCoreWeb.CreditCloses.ShowLive do
  @moduledoc """
  One monthly customer-credit close: review, approval, durable ERP posting,
  reconciliation evidence, remediation, and report downloads
  (BC-US-163…165, BC-TASK-104).

  Every state claim renders from durable rows — the close row, its
  movements, immutable evidence files, approval records, and the posting
  operation/sync/document triple.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Credits.Close, as: CloseKernel
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.Scope
  alias BillingCoreWeb.LiveHelpers

  @write_roles [:finance_operator, :billing_admin]

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:credit_closes} />

      <.header>
        Credit close · {period_label(@close)} · {@close.currency}
        <:subtitle>
          Opening → closing bridge frozen at {format_dt(@close.transaction_cutoff)} over {@close.ledger_transaction_count} ledger transactions.
        </:subtitle>
        <:actions>
          <span
            :if={@close.close_kind != :regular}
            id="close-kind"
            class="badge badge-outline badge-lg"
          >
            {@close.close_kind}
          </span>
          <.state_badge state={@close.state} class="badge-lg" id="close-state" />
        </:actions>
      </.header>

      <p
        :if={@close.close_kind != :regular}
        class="mb-4 text-sm opacity-70"
        id="close-correction-origin"
      >
        This {@close.close_kind} close corrects
        <.link
          navigate={~p"/teams/#{@team.id}/credit-closes/#{@close.reversal_of_close_id}"}
          class="link"
        >
          the original close
        </.link>
        of the same period (ADR-031); the frozen transaction membership remains on the original.
      </p>

      <div
        :if={@corrections != []}
        class="mb-4 rounded-lg border border-warning/40 bg-warning/10 p-4 text-sm"
        id="close-corrections"
      >
        <p class="font-semibold">Corrections of this close</p>
        <ul class="mt-1 space-y-1">
          <li :for={correction <- @corrections}>
            <.link
              navigate={~p"/teams/#{@team.id}/credit-closes/#{correction.id}"}
              class="link"
              id={"correction-#{correction.id}"}
            >
              {correction.close_kind}
            </.link>
            — <.state_badge state={correction.state} />
          </li>
        </ul>
      </div>

      <div class="mb-6 grid gap-3 sm:grid-cols-4" id="close-amounts">
        <div class="rounded-lg border border-base-300 p-4">
          <div class="text-xs opacity-60">Opening balance</div>
          <div class="mt-1 font-semibold tabular-nums">
            {format_money(@close.currency, @close.opening_minor)}
          </div>
        </div>
        <div class="rounded-lg border border-base-300 p-4">
          <div class="text-xs opacity-60">Net change</div>
          <div class="mt-1 font-semibold tabular-nums">
            {format_money(@close.currency, @close.net_change_minor)}
          </div>
        </div>
        <div class="rounded-lg border border-base-300 p-4">
          <div class="text-xs opacity-60">Closing balance</div>
          <div class="mt-1 font-semibold tabular-nums">
            {format_money(@close.currency, @close.closing_minor)}
          </div>
        </div>
        <div class="rounded-lg border border-base-300 p-4">
          <div class="text-xs opacity-60">ERP liability line</div>
          <div class="mt-1 font-semibold tabular-nums">
            {format_money(@close.currency, @close.economic_liability_line_minor)}
          </div>
        </div>
      </div>

      <div class="mb-6 rounded-lg border border-base-300 p-4" id="close-action-panel">
        <h2 class="mb-2 font-semibold">{action_title(@close.state)}</h2>
        <p class="mb-3 text-sm opacity-70">{action_body(@close.state)}</p>

        <%= cond do %>
          <% @close.state == :ready and @can_write? -> %>
            <.form for={@approve_form} id="approve-close-form" phx-submit="approve">
              <div class="flex flex-wrap items-end gap-2">
                <.input
                  field={@approve_form[:reason]}
                  type="text"
                  label="Approval reason"
                  placeholder="monthly finance review"
                />
                <.button variant="primary" phx-disable-with="Recording approval…">
                  Approve report {String.slice(@close.report_sha256 || "", 0, 12)}…
                </.button>
              </div>
            </.form>
          <% @close.state == :approved and @can_write? -> %>
            <.button
              id="post-close"
              variant="primary"
              phx-click="request_posting"
              phx-disable-with="Creating the durable posting operation…"
            >
              Post the aggregate voucher
            </.button>
          <% @close.state in [:posting, :outcome_unknown] -> %>
            <.button id="refresh-close" phx-click="refresh">Check progress</.button>
          <% @close.state == :reconciled and @can_write? -> %>
            <.button
              id="close-period"
              variant="primary"
              phx-click="close_period"
              phx-disable-with="Accepting the period…"
            >
              Accept and close the period
            </.button>
          <% @close.state == :closed and @can_write? and @close.close_kind != :reversal and
               @corrections == [] -> %>
            <details class="text-sm">
              <summary class="cursor-pointer select-none opacity-70 hover:opacity-100">
                Correct this close (reversal)…
              </summary>
              <p class="mt-2 mb-3 opacity-70">
                A posted close is immutable. Requesting a reversal freezes a compensating
                close with the exact negated bridge; its voucher cancels this one in the
                general ledger, after which a replacement can repost the period under a
                corrected policy (ADR-031).
              </p>
              <.form for={@reversal_form} id="request-reversal-form" phx-submit="request_reversal">
                <div class="flex flex-wrap items-end gap-2">
                  <.input
                    field={@reversal_form[:reason]}
                    type="text"
                    label="Correction reason"
                    required
                  />
                  <.button
                    variant="primary"
                    data-confirm="Freeze a reversal close for this period? The original becomes reversed once the reversal voucher reconciles."
                    phx-disable-with="Freezing the reversal…"
                  >
                    Request reversal
                  </.button>
                </div>
              </.form>
            </details>
          <% @close.state == :reversed and @can_write? -> %>
            <.form
              for={@replacement_form}
              id="generate-replacement-form"
              phx-submit="generate_replacement"
            >
              <div class="flex flex-wrap items-end gap-2">
                <.input
                  field={@replacement_form[:policy_version_id]}
                  type="select"
                  label="Corrected posting policy"
                  options={policy_options(@policies)}
                />
                <.input
                  field={@replacement_form[:reason]}
                  type="text"
                  label="Correction reason"
                  required
                />
                <.button variant="primary" phx-disable-with="Freezing the replacement…">
                  Generate replacement close
                </.button>
              </div>
            </.form>
          <% true -> %>
            <span class="text-sm opacity-60">No action required.</span>
        <% end %>
      </div>

      <div
        :if={@posting.operation}
        class="mb-6 rounded-lg border border-base-300 p-4"
        id="close-posting-status"
      >
        <h2 class="mb-2 font-semibold">Durable posting evidence</h2>
        <dl class="grid gap-3 text-sm sm:grid-cols-3">
          <div>
            <dt class="text-xs opacity-60">Operation</dt>
            <dd class="mt-1 flex items-center gap-2">
              <.state_badge state={@posting.operation.state} />
              <.link navigate={~p"/teams/#{@team.id}/operations"} class="link text-xs">
                Operations inbox
              </.link>
            </dd>
          </div>
          <div :if={@posting.sync_operation}>
            <dt class="text-xs opacity-60">Provider write · read-back</dt>
            <dd class="mt-1"><.state_badge state={@posting.sync_operation.state} /></dd>
          </div>
          <div :if={@posting.document}>
            <dt class="text-xs opacity-60">ERP voucher</dt>
            <dd class="mt-1 font-mono text-xs">
              {@posting.document.external_voucher_number || "pending"}
              <span :if={@posting.document.external_accounting_year} class="opacity-60">
                · year {@posting.document.external_accounting_year}
              </span>
            </dd>
          </div>
        </dl>
        <p :if={@posting.operation.state == "failed"} class="mt-3 text-sm text-error">
          The posting failed and needs attention. Use the operations inbox to inspect the exact
          provider error and retry — the operation key guarantees no duplicate voucher.
        </p>
      </div>

      <div class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">Movements in this period</h2>
        <p :if={@movements == []} class="text-sm opacity-70">
          No subledger movements — a zero-delta period.
        </p>
        <.table :if={@movements != []} id="close-movements" rows={@movements}>
          <:col :let={movement} label="Type">{movement.movement_type}</:col>
          <:col :let={movement} label="Transactions">
            <span class="tabular-nums">{movement.transaction_count}</span>
          </:col>
          <:col :let={movement} label="Amount">
            <span class="tabular-nums">{format_money(@close.currency, movement.amount_minor)}</span>
          </:col>
          <:col :let={movement} label="Liability effect">
            <span class="tabular-nums">
              {format_money(@close.currency, movement.liability_effect_minor)}
            </span>
          </:col>
        </.table>
      </div>

      <div class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">Immutable evidence</h2>
        <p class="mb-3 text-sm opacity-70">
          Report hash
          <span class="font-mono text-xs" title={@close.report_sha256}>{@close.report_sha256}</span>
        </p>
        <.table id="close-evidence" rows={@evidence}>
          <:col :let={item} label="File">{evidence_label(item.evidence_type)}</:col>
          <:col :let={item} label="SHA-256">
            <span class="font-mono text-xs" title={item.sha256}>
              {String.slice(item.sha256, 0, 16)}
            </span>
          </:col>
          <:col :let={item} label="Size">
            <span class="tabular-nums">{item.byte_size} B</span>
          </:col>
          <:action :let={item}>
            <.link
              href={~p"/teams/#{@team.id}/credit-closes/#{@close.id}/report/#{item.evidence_type}"}
              id={"download-#{item.evidence_type}"}
              class="link"
            >
              Download
            </.link>
          </:action>
        </.table>
      </div>

      <div :if={@approval} class="rounded-lg border border-base-300 p-4" id="close-approval">
        <h2 class="mb-2 font-semibold">Approval</h2>
        <p class="text-sm">
          Approved {format_dt(@approval.occurred_at)}
          <span :if={@approval.reason} class="opacity-70">— “{@approval.reason}”</span>
        </p>
        <p class="mt-1 text-xs opacity-60">
          Approval binds exactly report hash
          <span class="font-mono">{String.slice(@approval.close_hash || "", 0, 16)}</span>
          — a
          regenerated report would need a new approval.
        </p>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"id" => close_id}, _session, socket) do
    case CloseKernel.fetch(socket.assigns.scope, close_id) do
      {:ok, close} ->
        {:ok,
         socket
         |> assign(
           page_title: "Credit close · #{period_label(close)}",
           can_write?: Scope.has_team_role?(socket.assigns.scope, @write_roles),
           approve_form: to_form(%{"reason" => ""}, as: "approval"),
           reversal_form: to_form(%{"reason" => ""}, as: "reversal"),
           replacement_form:
             to_form(%{"policy_version_id" => nil, "reason" => ""}, as: "replacement")
         )
         |> assign_close(close)
         |> maybe_schedule_refresh()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Close not found.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/credit-closes")}
    end
  end

  def handle_event("approve", %{"approval" => params}, socket) do
    reason = params["reason"] |> to_string() |> String.trim()
    opts = if reason == "", do: [], else: [reason: reason]

    case CloseWorkflow.approve(socket.assigns.scope, socket.assigns.close.id, opts) do
      {:ok, close} ->
        {:noreply,
         socket
         |> put_flash(:info, "The exact report hash is approved for posting.")
         |> assign_close(close)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, close_error(reason))}
    end
  end

  def handle_event("request_posting", _params, socket) do
    case CloseWorkflow.request_posting(socket.assigns.scope, socket.assigns.close.id) do
      {:ok, _operation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The durable posting operation is queued — the voucher is searched before it is ever created."
         )
         |> reload_close()
         |> maybe_schedule_refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, close_error(reason))}
    end
  end

  def handle_event("close_period", _params, socket) do
    case CloseWorkflow.close_period(socket.assigns.scope, socket.assigns.close.id) do
      {:ok, close} ->
        {:noreply,
         socket
         |> put_flash(:info, "The period is closed — this bridge is now the accepted history.")
         |> assign_close(close)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, close_error(reason))}
    end
  end

  def handle_event("request_reversal", %{"reversal" => params}, socket) do
    reason = params["reason"] |> to_string() |> String.trim()

    case CloseWorkflow.request_reversal(socket.assigns.scope, socket.assigns.close.id,
           reason: reason
         ) do
      {:ok, reversal} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The reversal close is frozen. Approve and post it to cancel this voucher."
         )
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/credit-closes/#{reversal.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, close_error(reason))}
    end
  end

  def handle_event("generate_replacement", %{"replacement" => params}, socket) do
    reason = params["reason"] |> to_string() |> String.trim()

    case CloseWorkflow.generate_replacement(socket.assigns.scope, socket.assigns.close.id,
           policy_version_id: params["policy_version_id"],
           reason: reason
         ) do
      {:ok, replacement} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "The replacement close is frozen with the exact original figures under the corrected policy."
         )
         |> push_navigate(
           to: ~p"/teams/#{socket.assigns.team.id}/credit-closes/#{replacement.id}"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, close_error(reason))}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> reload_close() |> maybe_schedule_refresh()}
  end

  def handle_info(:refresh_close, socket) do
    {:noreply, socket |> reload_close() |> maybe_schedule_refresh()}
  end

  defp reload_close(socket) do
    case CloseKernel.fetch(socket.assigns.scope, socket.assigns.close.id) do
      {:ok, close} -> assign_close(socket, close)
      {:error, _reason} -> socket
    end
  end

  defp assign_close(socket, close) do
    scope = socket.assigns.scope
    {:ok, movements} = CloseWorkflow.list_movements(scope, close.id)
    {:ok, evidence} = CloseWorkflow.list_evidence_meta(scope, close.id)
    {:ok, approval} = CloseWorkflow.latest_approval(scope, close.id)
    {:ok, posting} = CloseWorkflow.posting_status(scope, close)
    {:ok, corrections} = CloseWorkflow.list_corrections(scope, close.id)
    {:ok, policies} = CloseWorkflow.list_policies(scope)

    assign(socket,
      close: close,
      movements: movements,
      evidence: evidence,
      approval: approval,
      posting: posting,
      corrections: corrections,
      policies: policies
    )
  end

  defp policy_options(policies) do
    Enum.map(policies, fn policy ->
      {"v#{policy.version} · journal #{policy.journal_number} · account #{policy.liability_account_number}",
       policy.id}
    end)
  end

  defp maybe_schedule_refresh(socket) do
    if connected?(socket) and socket.assigns.close.state in [:posting, :outcome_unknown] do
      Process.send_after(self(), :refresh_close, 2_000)
    end

    socket
  end

  defp period_label(close), do: Calendar.strftime(close.period_start, "%B %Y")

  defp evidence_label(:canonical_json), do: "Canonical report (JSON)"
  defp evidence_label(:csv_detail), do: "Transaction detail (CSV)"
  defp evidence_label(:pdf_summary), do: "Signed summary (PDF)"
  defp evidence_label(:manifest), do: "Checksum manifest"
  defp evidence_label(:erp_voucher), do: "ERP voucher read-back"
  defp evidence_label(:erp_attachment), do: "ERP attachment read-back"
  defp evidence_label(:reconciliation), do: "Reconciliation result"
  defp evidence_label(other), do: to_string(other)

  defp action_title(:ready), do: "Review and approve"
  defp action_title(:approved), do: "Post to the general ledger"
  defp action_title(:posting), do: "Posting in progress"
  defp action_title(:outcome_unknown), do: "Outcome recovery in progress"
  defp action_title(:reconciled), do: "Reconciled — accept the period"
  defp action_title(:posted), do: "Posted — awaiting reconciliation"
  defp action_title(:mismatch), do: "Reconciliation mismatch"
  defp action_title(:closed), do: "Period closed"
  defp action_title(:reversal_pending), do: "Reversal in progress"
  defp action_title(:reversed), do: "Reversed — replacement required"
  defp action_title(_state), do: "Close state"

  defp action_body(:ready),
    do:
      "Verify the movements and the report evidence below. Approving binds the exact report hash; the posted voucher must match it."

  defp action_body(:approved),
    do:
      "Posting creates one durable, idempotent operation: search the voucher by stable reference, create it only if missing, attach the report, and reconcile the authoritative read-back."

  defp action_body(:posting),
    do:
      "The durable operation is executing against the provider. This page re-derives the state as it completes."

  defp action_body(:outcome_unknown),
    do:
      "The provider response was lost after a write may have committed. Recovery searches by the stable reference before any retry — no duplicate voucher is possible."

  defp action_body(:reconciled),
    do:
      "The voucher and attachment were read back and match the approved report exactly. Accepting makes this the authoritative period close."

  defp action_body(:posted),
    do: "The voucher exists in the provider; reconciliation evidence is being finalized."

  defp action_body(:mismatch),
    do:
      "The provider's authoritative document differs from the approved report. Investigate through the operations inbox before any remediation."

  defp action_body(:closed),
    do:
      "This period is accepted history. If it later proves wrong, a compensating reversal/replacement corrects it — never an edit."

  defp action_body(:reversal_pending),
    do:
      "A reversal close for this period is being posted. This close becomes reversed once the reversal voucher reconciles."

  defp action_body(:reversed),
    do:
      "This close's voucher was reversed in the general ledger. Freeze a replacement under the corrected policy to restore the period's bridge — the next month cannot close without it."

  defp action_body(_state),
    do: "This close is not currently awaiting an operator decision."

  defp close_error({:invalid_close_state, state, expected}),
    do: "That action is not allowed in state #{state} (requires #{inspect(expected)})."

  defp close_error({:illegal_close_transition, _error}),
    do: "That action is not allowed in the close's current state."

  defp close_error(:approval_missing_or_stale),
    do: "The approval is missing or no longer matches the report hash."

  defp close_error({:connection_not_usable, status}),
    do: "The ERP connection is #{status}; validate it in settings first."

  defp close_error(:correction_reason_required),
    do: "A correction needs an explicit reason for the audit trail."

  defp close_error(:cannot_reverse_a_reversal),
    do: "A reversal close cannot itself be reversed — correct through a replacement."

  defp close_error({:already_exists, _id}),
    do: "This period already has an active close."

  defp close_error(:ledger_snapshot_mismatch),
    do:
      "The recomputed ledger snapshot no longer matches the frozen original — investigate before replacing."

  defp close_error(reason), do: LiveHelpers.error_message(reason)
end
