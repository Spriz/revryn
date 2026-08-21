defmodule BillingCoreWeb.SubscriptionLive.Index do
  @moduledoc "Team subscriptions listing (SPEC §11.1 lifecycle states)."

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Contracts

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:subscriptions} />

      <.header>
        Subscriptions
        <:subtitle>Versioned subscriptions across the team's contracts.</:subtitle>
      </.header>

      <.empty_state :if={@subscriptions == []} id="no-subscriptions">
        No subscriptions yet — start one from a customer's contract via the API.
      </.empty_state>

      <.table
        :if={@subscriptions != []}
        id="subscriptions"
        rows={@subscriptions}
        row_click={
          fn subscription ->
            JS.navigate(~p"/teams/#{@team.id}/subscriptions/#{subscription.id}")
          end
        }
      >
        <:col :let={subscription} label="External ID">
          <span class="font-medium">{subscription.external_id}</span>
        </:col>
        <:col :let={subscription} label="Status">
          <.state_badge state={subscription.status} />
        </:col>
        <:col :let={subscription} label="Start">{subscription.start_date}</:col>
        <:col :let={subscription} label="End (exclusive)">
          {subscription.end_date_exclusive || "—"}
        </:col>
        <:col :let={subscription} label="Version">v{subscription.current_version}</:col>
        <:action :let={subscription}>
          <.link navigate={~p"/teams/#{@team.id}/subscriptions/#{subscription.id}"} class="link">
            View
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, subscriptions} = Contracts.list_subscriptions(socket.assigns.scope)
    {:ok, assign(socket, page_title: "Subscriptions", subscriptions: subscriptions)}
  end
end
