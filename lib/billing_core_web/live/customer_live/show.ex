defmodule BillingCoreWeb.CustomerLive.Show do
  @moduledoc """
  Customer detail: immutable version history, contracts and subscriptions,
  invoices, ERP customer mapping (BC-US-031), and linked credit-account
  balances (BC-US-108).
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.{Billing, Contracts, Credits}
  alias BillingCore.ERP
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:customers} />

      <.header>
        {@current_version && @current_version.legal_name}
        <:subtitle>
          {@customer.external_id} · v{@customer.current_version}
          <.state_badge state={@customer.status} class="ml-1" />
        </:subtitle>
      </.header>

      <div class="grid gap-6 lg:grid-cols-2">
        <section class="space-y-6">
          <div class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Details</h2>
            <.form for={@edit_form} id="edit-customer-form" phx-submit="save_customer">
              <div class="grid gap-x-4 sm:grid-cols-2">
                <.input field={@edit_form[:legal_name]} type="text" label="Legal name" required />
                <.input field={@edit_form[:email]} type="email" label="Billing email" required />
                <.input field={@edit_form[:country]} type="text" label="Country" required />
                <.input field={@edit_form[:vat_number]} type="text" label="VAT number" />
                <.input field={@edit_form[:address_line]} type="text" label="Address" />
                <.input field={@edit_form[:zip]} type="text" label="ZIP" />
                <.input field={@edit_form[:city]} type="text" label="City" />
                <.input
                  field={@edit_form[:currency_preference]}
                  type="text"
                  label="Currency preference"
                />
              </div>
              <.button class="mt-2" phx-disable-with="Saving…">Save new version</.button>
            </.form>
          </div>

          <div class="rounded-lg border border-base-300 p-4" id="erp-mapping-card">
            <h2 class="mb-2 font-semibold">ERP mapping</h2>
            <ul :if={@mappings != []} id="customer-mappings" class="mb-3 space-y-1 text-sm">
              <li :for={mapping <- @mappings}>
                Customer number
                <span class="font-mono font-medium">{mapping.external_customer_number}</span>
                <.state_badge state={mapping.validation_status} class="ml-1" />
              </li>
            </ul>
            <p :if={!@connection} class="text-sm opacity-70">
              Configure an ERP connection in settings before mapping customers.
            </p>
            <.form
              :if={@connection}
              for={@mapping_form}
              id="customer-mapping-form"
              phx-submit="save_mapping"
            >
              <div class="flex items-end gap-2">
                <.input
                  field={@mapping_form[:erp_connection_id]}
                  type="select"
                  label="Connection"
                  options={[{@connection.provider, @connection.id}]}
                />
                <.input
                  field={@mapping_form[:external_customer_number]}
                  type="text"
                  label="ERP customer number"
                  required
                />
                <.button phx-disable-with="Saving…">Save mapping</.button>
              </div>
            </.form>
          </div>

          <div class="rounded-lg border border-base-300 p-4" id="credit-accounts-card">
            <h2 class="mb-2 font-semibold">Customer credit</h2>
            <p :if={@credit_accounts == []} class="text-sm opacity-70">
              Not linked to a commercial account with credit.
            </p>
            <table :if={@credit_accounts != []} class="table table-sm" id="credit-accounts">
              <thead>
                <tr>
                  <th>Currency</th>
                  <th>Available</th>
                  <th>Reserved</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={account <- @credit_accounts} id={"credit-account-#{account.id}"}>
                  <td>{account.currency}</td>
                  <td><.money currency={account.currency} minor={account.available_minor} /></td>
                  <td><.money currency={account.currency} minor={account.reserved_minor} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="space-y-6">
          <div class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Contracts &amp; subscriptions</h2>
            <p :if={@contracts == []} class="text-sm opacity-70">No contracts yet.</p>
            <div :for={{contract, subscriptions} <- @contracts} class="mb-3">
              <p class="text-sm font-medium">
                {contract.external_reference} · {contract.currency}
                <.state_badge state={contract.status} class="ml-1" />
              </p>
              <ul class="mt-1 space-y-1 text-sm">
                <li :for={subscription <- subscriptions}>
                  <.link
                    navigate={~p"/teams/#{@team.id}/subscriptions/#{subscription.id}"}
                    class="link"
                  >
                    {subscription.external_id}
                  </.link>
                  <.state_badge state={subscription.status} class="ml-1" />
                </li>
                <li :if={subscriptions == []} class="opacity-60">No subscriptions.</li>
              </ul>
            </div>
          </div>

          <div class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Invoices</h2>
            <p :if={@intents == []} class="text-sm opacity-70">No invoice intent yet.</p>
            <table :if={@intents != []} class="table table-sm" id="customer-intents">
              <thead>
                <tr>
                  <th>Date</th>
                  <th>Kind</th>
                  <th>Net</th>
                  <th>State</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={%{intent: intent, state: state} <- @intents} id={"intent-#{intent.id}"}>
                  <td>
                    <.link navigate={~p"/teams/#{@team.id}/invoices/#{intent.id}"} class="link">
                      {intent.invoice_date}
                    </.link>
                  </td>
                  <td>{intent.document_kind}</td>
                  <td><.money currency={intent.currency} minor={intent.net_amount_minor} /></td>
                  <td><.state_badge state={state} /></td>
                </tr>
              </tbody>
            </table>
          </div>

          <div class="rounded-lg border border-base-300 p-4">
            <h2 class="mb-2 font-semibold">Version history</h2>
            <table class="table table-sm" id="customer-versions">
              <thead>
                <tr>
                  <th>Version</th>
                  <th>Legal name</th>
                  <th>Email</th>
                  <th>Created</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={version <- @versions} id={"customer-version-#{version.version}"}>
                  <td>v{version.version}</td>
                  <td>{version.legal_name}</td>
                  <td>{version.email}</td>
                  <td>{format_dt(version.created_at)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"id" => id}, _session, socket) do
    case Contracts.get_customer(socket.assigns.scope, id) do
      {:ok, customer} ->
        {:ok,
         socket
         |> assign(customer: customer)
         |> refresh()}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Customer not found.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/customers")}
    end
  end

  def handle_event("save_customer", %{"customer" => params}, socket) do
    customer = socket.assigns.customer

    attrs =
      params
      |> Map.take(
        ~w(legal_name email country vat_number currency_preference address_line zip city)
      )
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.put(:external_id, customer.external_id)

    case Contracts.upsert_customer(socket.assigns.scope, attrs) do
      {:ok, %{version: nil}} ->
        {:noreply, put_flash(socket, :info, "No changes — customer is already up to date.")}

      {:ok, %{customer: customer}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Customer version v#{customer.current_version} recorded.")
         |> assign(customer: customer)
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("save_mapping", %{"mapping" => params}, socket) do
    attrs = %{
      erp_connection_id: params["erp_connection_id"],
      external_customer_number: params["external_customer_number"]
    }

    case Contracts.upsert_customer_erp_mapping(
           socket.assigns.scope,
           socket.assigns.customer,
           attrs
         ) do
      {:ok, mapping} ->
        {:noreply,
         socket
         |> put_flash(:info, "Mapped to ERP customer #{mapping.external_customer_number}.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp refresh(socket) do
    scope = socket.assigns.scope
    customer = socket.assigns.customer

    {:ok, versions} = Contracts.list_customer_versions(scope, customer)
    current_version = List.last(versions)
    {:ok, contracts} = Contracts.list_contracts(scope, customer_id: customer.id)

    contracts_with_subs =
      Enum.map(contracts, fn contract ->
        {:ok, subscriptions} = Contracts.list_subscriptions(scope, contract_id: contract.id)
        {contract, subscriptions}
      end)

    {:ok, mappings} = Contracts.list_customer_erp_mappings(scope, customer)
    {:ok, intents} = Billing.list_intents(scope, customer_id: customer.id)
    {:ok, credit_accounts} = Credits.list_accounts_for_customer(scope, customer.id)

    connection =
      case ERP.get_connection(scope) do
        {:ok, connection} -> connection
        {:error, :not_found} -> nil
      end

    assign(socket,
      page_title: customer.external_id,
      versions: versions,
      current_version: current_version,
      contracts: contracts_with_subs,
      mappings: mappings,
      intents: intents,
      credit_accounts: credit_accounts,
      connection: connection,
      edit_form: edit_form(current_version),
      mapping_form: mapping_form(connection, mappings)
    )
  end

  defp edit_form(nil), do: to_form(%{}, as: "customer")

  defp edit_form(version) do
    to_form(
      %{
        "legal_name" => version.legal_name,
        "email" => version.email,
        "country" => version.country,
        "vat_number" => version.vat_number,
        "currency_preference" => version.currency_preference,
        "address_line" => version.address_line,
        "zip" => version.zip,
        "city" => version.city
      },
      as: "customer"
    )
  end

  defp mapping_form(nil, _mappings), do: to_form(%{}, as: "mapping")

  defp mapping_form(connection, mappings) do
    existing = Enum.find(mappings, &(&1.erp_connection_id == connection.id))

    to_form(
      %{
        "erp_connection_id" => connection.id,
        "external_customer_number" => existing && existing.external_customer_number
      },
      as: "mapping"
    )
  end
end
