defmodule BillingCoreWeb.TeamLive.Overview do
  @moduledoc """
  Team overview: headline counts, ERP connection status, and quick links
  into the team-scoped billing surfaces.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.{Billing, Contracts, Operations}
  alias BillingCore.ERP

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:overview} />

      <.header>
        {@team.name}
        <:subtitle>{@team.legal_name} · {@team.base_currency} · {@team.time_zone}</:subtitle>
      </.header>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" id="overview-counts">
        <.stat_card
          id="stat-customers"
          label="Customers"
          value={@customer_count}
          navigate={~p"/teams/#{@team.id}/customers"}
        />
        <.stat_card
          id="stat-subscriptions"
          label="Active subscriptions"
          value={@active_subscription_count}
          navigate={~p"/teams/#{@team.id}/subscriptions"}
        />
        <.stat_card
          id="stat-open-runs"
          label="Open billing runs"
          value={@open_run_count}
          navigate={~p"/teams/#{@team.id}/billing-runs"}
        />
        <.stat_card
          id="stat-failure-inbox"
          label="Failure inbox"
          value={@failure_inbox_count}
          navigate={~p"/teams/#{@team.id}/operations"}
          alert={@failure_inbox_count > 0}
        />
      </div>

      <section class="mt-8 grid gap-4 lg:grid-cols-2">
        <div class="rounded-lg border border-base-300 p-4" id="erp-connection-card">
          <h2 class="font-semibold">ERP connection</h2>
          <div :if={@connection} class="mt-2 space-y-1 text-sm">
            <p>
              Provider <span class="font-medium">{@connection.provider}</span>
              <.state_badge state={@connection.status} class="ml-2" />
            </p>
            <p :if={@connection.last_validated_at} class="opacity-70">
              Last validated {format_dt(@connection.last_validated_at)}
            </p>
            <p class="pt-2">
              <.link navigate={~p"/teams/#{@team.id}/settings"} class="link text-sm">
                Manage connection
              </.link>
            </p>
          </div>
          <div :if={!@connection} class="mt-2 text-sm opacity-70">
            No ERP connection configured yet.
            <.link navigate={~p"/teams/#{@team.id}/settings"} class="link">
              Set one up in settings
            </.link>
          </div>
        </div>

        <div class="rounded-lg border border-base-300 p-4">
          <h2 class="font-semibold">Quick links</h2>
          <ul class="mt-2 space-y-1 text-sm">
            <li>
              <.link navigate={~p"/teams/#{@team.id}/billing-runs"} class="link">
                Process a billing run
              </.link>
            </li>
            <li>
              <.link navigate={~p"/teams/#{@team.id}/catalog"} class="link">
                Manage products and plans
              </.link>
            </li>
            <li>
              <.link navigate={~p"/teams/#{@team.id}/operations"} class="link">
                Review failed operations
              </.link>
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :navigate, :string, required: true
  attr :alert, :boolean, default: false

  defp stat_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      id={@id}
      class={[
        "rounded-lg border p-4 transition-colors hover:bg-base-200",
        if(@alert, do: "border-error", else: "border-base-300")
      ]}
    >
      <span class="block text-3xl font-semibold tabular-nums">{@value}</span>
      <span class="block text-sm opacity-70">{@label}</span>
    </.link>
    """
  end

  def mount(_params, _session, socket) do
    scope = socket.assigns.scope

    {:ok, customer_count} = Contracts.count_customers(scope)
    {:ok, active_subscription_count} = Contracts.count_subscriptions(scope, :active)
    {:ok, open_run_count} = Billing.count_open_runs(scope)
    failure_inbox_count = length(Operations.failure_inbox(scope.team.id))

    connection =
      case ERP.get_connection(scope) do
        {:ok, connection} -> connection
        {:error, :not_found} -> nil
      end

    {:ok,
     assign(socket,
       page_title: socket.assigns.team.name,
       customer_count: customer_count,
       active_subscription_count: active_subscription_count,
       open_run_count: open_run_count,
       failure_inbox_count: failure_inbox_count,
       connection: connection
     )}
  end
end
