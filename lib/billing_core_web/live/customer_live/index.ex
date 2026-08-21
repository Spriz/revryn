defmodule BillingCoreWeb.CustomerLive.Index do
  @moduledoc """
  Team customers: listing plus creation via the idempotent
  `Contracts.upsert_customer/2` command (BC-US-030).
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Contracts
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:customers} />

      <.header>
        Customers
        <:subtitle>Team-owned billing customers with immutable version history.</:subtitle>
        <:actions>
          <.button
            variant="primary"
            phx-click={show("#new-customer") |> JS.focus_first(to: "#new-customer")}
          >
            New customer
          </.button>
        </:actions>
      </.header>

      <div id="new-customer" hidden class="mb-6 rounded-lg border border-base-300 p-4">
        <h2 class="mb-2 font-semibold">New customer</h2>
        <.form for={@new_form} id="new-customer-form" phx-submit="create_customer">
          <div class="grid gap-x-4 sm:grid-cols-2">
            <.input field={@new_form[:external_id]} type="text" label="External ID" required />
            <.input field={@new_form[:legal_name]} type="text" label="Legal name" required />
            <.input field={@new_form[:email]} type="email" label="Billing email" required />
            <.input
              field={@new_form[:country]}
              type="text"
              label="Country (ISO 3166-1)"
              placeholder="DK"
              required
            />
            <.input field={@new_form[:vat_number]} type="text" label="VAT number" />
            <.input
              field={@new_form[:currency_preference]}
              type="text"
              label="Currency preference"
              placeholder="DKK"
            />
            <.input field={@new_form[:address_line]} type="text" label="Address" />
            <.input field={@new_form[:zip]} type="text" label="ZIP" />
            <.input field={@new_form[:city]} type="text" label="City" />
          </div>
          <.button variant="primary" class="mt-2" phx-disable-with="Saving…">
            Create customer
          </.button>
        </.form>
      </div>

      <.empty_state :if={@customers == []} id="no-customers">
        No customers yet — create the first one to start invoicing.
      </.empty_state>

      <.table
        :if={@customers != []}
        id="customers"
        rows={@customers}
        row_click={fn customer -> JS.navigate(~p"/teams/#{@team.id}/customers/#{customer.id}") end}
      >
        <:col :let={customer} label="External ID">
          <span class="font-medium">{customer.external_id}</span>
        </:col>
        <:col :let={customer} label="Status"><.state_badge state={customer.status} /></:col>
        <:col :let={customer} label="Version">v{customer.current_version}</:col>
        <:action :let={customer}>
          <.link navigate={~p"/teams/#{@team.id}/customers/#{customer.id}"} class="link">
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
     |> assign(page_title: "Customers", new_form: to_form(%{}, as: "customer"))
     |> load_customers()}
  end

  def handle_event("create_customer", %{"customer" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(external_id legal_name email country vat_number currency_preference
                     address_line zip city))
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)

    case Contracts.upsert_customer(socket.assigns.scope, attrs) do
      {:ok, %{customer: customer}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Customer #{customer.external_id} saved.")
         |> assign(new_form: to_form(%{}, as: "customer"))
         |> load_customers()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp load_customers(socket) do
    {:ok, customers} = Contracts.list_customers(socket.assigns.scope)
    assign(socket, :customers, customers)
  end
end
