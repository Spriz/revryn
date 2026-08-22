defmodule BillingCoreWeb.CreditCloses.IndexLive do
  @moduledoc """
  Monthly customer-credit closes: listing, posting-policy setup, and
  deterministic close generation (BC-US-163…165, BC-TASK-104).

  Thin adapter over `BillingCore.Credits.CloseWorkflow` — the same commands
  GraphQL, revryn, and MCP invoke.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Credits.Close, as: CloseKernel
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.Domain.Money
  alias BillingCore.Scope
  alias BillingCoreWeb.LiveHelpers

  @write_roles [:finance_operator, :billing_admin]

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:credit_closes} />

      <.header>
        Customer-credit closes
        <:subtitle>
          One immutable close per currency and calendar month bridges the detailed credit
          subledger to a single aggregate ERP liability voucher.
        </:subtitle>
      </.header>

      <div :if={@policies == [] and @can_write?} class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-1 font-semibold">Posting policy required</h2>
        <p class="mb-3 text-sm opacity-70">
          The first close needs an accountant-approved posting policy: the journal that receives
          the aggregate voucher and the liability account that carries the customer-credit
          balance.
        </p>
        <.form for={@policy_form} id="close-policy-form" phx-submit="create_policy">
          <div class="grid gap-2 sm:grid-cols-3">
            <.input
              field={@policy_form[:journal_number]}
              type="number"
              label="Journal number"
              required
            />
            <.input
              field={@policy_form[:liability_account_number]}
              type="number"
              label="Liability account"
              required
            />
            <.input
              field={@policy_form[:default_offset_account_number]}
              type="number"
              label="Offset account"
              required
            />
          </div>
          <div class="mt-2 flex items-center justify-between gap-4">
            <.input
              field={@policy_form[:post_zero_delta]}
              type="checkbox"
              label="Post months with a zero net change to the ERP"
            />
            <.button variant="primary" phx-disable-with="Creating policy…">Create policy</.button>
          </div>
        </.form>
      </div>

      <div :if={@policies != [] and @can_write?} class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">Generate a close</h2>
        <.form for={@close_form} id="generate-close-form" phx-submit="generate_close">
          <div class="flex flex-wrap items-end gap-2">
            <.input
              field={@close_form[:period_date]}
              type="date"
              label="Any date in the period month"
              required
            />
            <.input field={@close_form[:currency]} type="text" label="Currency" required />
            <.input
              :if={@closes == []}
              field={@close_form[:bootstrap_opening]}
              type="text"
              label="Opening balance (first close only)"
            />
            <.button variant="primary" phx-disable-with="Freezing the close…">
              Generate close
            </.button>
          </div>
        </.form>
        <p class="mt-1 text-xs opacity-60">
          Generation freezes the ledger at the current instant, computes opening → closing
          exactly, and stores the immutable JSON/CSV/PDF/manifest evidence before anything is
          posted.
        </p>
      </div>

      <.empty_state :if={@closes == []} id="no-closes">
        No closes yet — the credit subledger has not been bridged to the general ledger for any
        month.
      </.empty_state>

      <.table
        :if={@closes != []}
        id="credit-closes"
        rows={@closes}
        row_click={fn close -> JS.navigate(~p"/teams/#{@team.id}/credit-closes/#{close.id}") end}
      >
        <:col :let={close} label="Period">
          <span class="font-medium tabular-nums">{period_label(close)}</span>
        </:col>
        <:col :let={close} label="Currency">{close.currency}</:col>
        <:col :let={close} label="Kind">
          <span class={[close.close_kind != :regular && "badge badge-outline badge-sm"]}>
            {if close.close_kind == :regular, do: "—", else: close.close_kind}
          </span>
        </:col>
        <:col :let={close} label="State"><.state_badge state={close.state} /></:col>
        <:col :let={close} label="Opening">
          <span class="tabular-nums">{format_money(close.currency, close.opening_minor)}</span>
        </:col>
        <:col :let={close} label="Net change">
          <span class="tabular-nums">{format_money(close.currency, close.net_change_minor)}</span>
        </:col>
        <:col :let={close} label="Closing">
          <span class="tabular-nums">{format_money(close.currency, close.closing_minor)}</span>
        </:col>
        <:col :let={close} label="Report hash">
          <span class="font-mono text-xs" title={close.report_sha256}>
            {String.slice(close.report_sha256 || "", 0, 12)}
          </span>
        </:col>
        <:action :let={close}>
          <.link navigate={~p"/teams/#{@team.id}/credit-closes/#{close.id}"} class="link">
            View
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Credit closes",
       can_write?: Scope.has_team_role?(socket.assigns.scope, @write_roles),
       close_form:
         to_form(
           %{
             "period_date" => Date.to_iso8601(Date.utc_today()),
             "currency" => socket.assigns.team.base_currency,
             "bootstrap_opening" => "0.00"
           },
           as: "close"
         ),
       policy_form:
         to_form(
           %{
             "journal_number" => nil,
             "liability_account_number" => nil,
             "default_offset_account_number" => nil,
             "post_zero_delta" => false
           },
           as: "policy"
         )
     )
     |> load_data()}
  end

  def handle_event("create_policy", %{"policy" => params}, socket) do
    scope = socket.assigns.scope
    version = length(socket.assigns.policies) + 1

    attrs = %{
      version: version,
      effective_from: Date.beginning_of_month(Date.utc_today()),
      journal_number: params["journal_number"],
      liability_account_number: params["liability_account_number"],
      posting_mode: :single_offset,
      default_offset_account_number: params["default_offset_account_number"],
      post_zero_delta: params["post_zero_delta"] in [true, "true", "on"],
      vat_neutral: true,
      created_by: scope.user && scope.user.id
    }

    case CloseKernel.create_policy(scope, attrs) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Posting policy created. You can generate the first close.")
         |> load_data()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The posting policy could not be created.")}
    end
  end

  def handle_event("generate_close", %{"close" => params}, socket) do
    scope = socket.assigns.scope

    with {:ok, date} <- LiveHelpers.parse_date(params["period_date"]),
         {:ok, opening_minor} <- parse_opening(params["bootstrap_opening"], params["currency"]),
         %{} = policy <- List.first(socket.assigns.policies) || {:error, :no_policy},
         {:ok, close} <-
           CloseWorkflow.generate(scope, %{
             currency: params["currency"],
             period_start: Date.beginning_of_month(date),
             period_end_exclusive: Date.add(Date.end_of_month(date), 1),
             transaction_cutoff: DateTime.utc_now(),
             policy_version_id: policy.id,
             bootstrap_opening_minor: opening_minor
           }) do
      {:noreply,
       socket
       |> put_flash(:info, "The close is frozen with its exact report evidence.")
       |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/credit-closes/#{close.id}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, generate_error(reason))}
    end
  end

  defp load_data(socket) do
    scope = socket.assigns.scope
    {:ok, closes} = CloseWorkflow.list_closes(scope)
    {:ok, policies} = CloseWorkflow.list_policies(scope)
    assign(socket, closes: closes, policies: policies)
  end

  defp parse_opening(nil, _currency), do: {:ok, 0}
  defp parse_opening("", _currency), do: {:ok, 0}

  defp parse_opening(input, currency) when is_binary(input) do
    {:ok, Money.round_major(Decimal.new(String.trim(input)), currency).minor_units}
  rescue
    _invalid -> {:error, :invalid_opening}
  end

  defp period_label(close) do
    Calendar.strftime(close.period_start, "%B %Y")
  end

  defp generate_error(:invalid_date), do: "Enter a valid date inside the period month."
  defp generate_error(:invalid_opening), do: "Enter the opening balance as a plain amount."
  defp generate_error(:no_policy), do: "Create a posting policy first."

  defp generate_error({:already_exists, _close_id}),
    do: "That period and currency already have a close."

  defp generate_error({:previous_close_not_accepted, _state}),
    do: "The prior period's close must be reconciled or closed before this month can freeze."

  defp generate_error(:bootstrap_opening_required),
    do: "The very first close needs an explicit opening balance (zero is valid)."

  defp generate_error(:close_policy_not_effective),
    do: "No posting policy is effective on that period's start date."

  defp generate_error(:invalid_close_attributes),
    do: "The close inputs are incomplete — check the period, currency, and policy."

  defp generate_error(%Ecto.Changeset{} = changeset), do: LiveHelpers.error_message(changeset)
  defp generate_error(reason), do: LiveHelpers.error_message(reason)
end
