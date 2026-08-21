defmodule BillingCoreWeb.CatalogLive.Index do
  @moduledoc """
  Product and plan catalog (BC-US-010…014): products with ERP mappings and
  deactivation, plans with their version timelines.
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Catalog
  alias BillingCore.ERP
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:catalog} />

      <.header>
        Catalog
        <:subtitle>Products, plans, and immutable plan versions.</:subtitle>
      </.header>

      <section class="space-y-4">
        <h2 class="text-lg font-semibold">Products</h2>

        <.empty_state :if={@products == []} id="no-products">
          No products yet — create one to build plans on.
        </.empty_state>

        <.table :if={@products != []} id="products" rows={@products}>
          <:col :let={product} label="Code">
            <span class="font-mono">{product.code}</span>
          </:col>
          <:col :let={product} label="Name">{product.name}</:col>
          <:col :let={product} label="Recognition">{product.recognition_mode}</:col>
          <:col :let={product} label="ERP number">
            <span :for={mapping <- Map.get(@product_mappings, product.id, [])} class="mr-1">
              <span class="font-mono">{mapping.external_product_number}</span>
              <.state_badge state={mapping.validation_status} />
            </span>
            <span :if={Map.get(@product_mappings, product.id, []) == []} class="opacity-50">—</span>
          </:col>
          <:col :let={product} label="Status"><.state_badge state={product.status} /></:col>
          <:action :let={product}>
            <.button
              :if={product.status == :active}
              id={"deactivate-product-#{product.id}"}
              phx-click="deactivate_product"
              phx-value-id={product.id}
              data-confirm="Deactivate this product? Plans using it can no longer be published."
              phx-disable-with="Deactivating…"
            >
              Deactivate
            </.button>
          </:action>
        </.table>

        <div class="grid gap-4 lg:grid-cols-2">
          <div class="rounded-lg border border-base-300 p-4">
            <h3 class="mb-2 font-semibold">New product</h3>
            <.form for={@product_form} id="new-product-form" phx-submit="create_product">
              <div class="grid gap-x-4 sm:grid-cols-2">
                <.input field={@product_form[:code]} type="text" label="Code" required />
                <.input field={@product_form[:name]} type="text" label="Name" required />
                <.input
                  field={@product_form[:recognition_mode]}
                  type="select"
                  label="Recognition"
                  options={[{"Point in time", "point_in_time"}, {"Over time", "over_time"}]}
                />
                <.input
                  field={@product_form[:service_period_source]}
                  type="select"
                  label="Service period source"
                  prompt="— (point in time)"
                  options={[
                    {"Billing period", "billing_period"},
                    {"Subscription period", "subscription_period"},
                    {"Explicit", "explicit"}
                  ]}
                />
              </div>
              <.input field={@product_form[:description]} type="text" label="Description" />
              <.button variant="primary" class="mt-2" phx-disable-with="Creating…">
                Create product
              </.button>
            </.form>
          </div>

          <div class="rounded-lg border border-base-300 p-4" id="product-mapping-card">
            <h3 class="mb-2 font-semibold">Map product to ERP</h3>
            <p :if={!@connection} class="text-sm opacity-70">
              Configure an ERP connection in settings first.
            </p>
            <.form
              :if={@connection && @products != []}
              for={@mapping_form}
              id="product-mapping-form"
              phx-submit="save_product_mapping"
            >
              <.input
                field={@mapping_form[:product_id]}
                type="select"
                label="Product"
                prompt="Choose a product"
                options={Enum.map(@products, &{"#{&1.code} — #{&1.name}", &1.id})}
              />
              <.input
                field={@mapping_form[:external_product_number]}
                type="text"
                label="ERP product number"
                required
              />
              <.button class="mt-2" phx-disable-with="Saving…">Save mapping</.button>
            </.form>
          </div>
        </div>
      </section>

      <section class="mt-10 space-y-4">
        <h2 class="text-lg font-semibold">Plans</h2>

        <.empty_state :if={@plans == []} id="no-plans">
          No plans yet.
        </.empty_state>

        <div :for={{plan, versions} <- @plans} class="rounded-lg border border-base-300 p-4">
          <p class="font-medium">
            {plan.name}
            <span class="ml-1 font-mono text-sm opacity-70">{plan.code}</span>
            <.state_badge state={plan.status} class="ml-2" />
          </p>
          <ul id={"plan-#{plan.id}-versions"} class="mt-2 space-y-1 text-sm">
            <li :for={version <- versions}>
              <.link
                navigate={~p"/teams/#{@team.id}/catalog/plan-versions/#{version.id}"}
                class="link"
                id={"plan-version-link-#{version.id}"}
              >
                v{version.version}
              </.link>
              <.state_badge state={version.status} class="ml-1" />
              <span class="ml-1 opacity-70">
                {version.currency} · every {version.interval_count} {version.interval_unit}(s) · {version.billing_timing}
              </span>
            </li>
            <li :if={versions == []} class="opacity-60">No versions yet.</li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Catalog",
       product_form: to_form(%{}, as: "product"),
       mapping_form: to_form(%{}, as: "mapping")
     )
     |> refresh()}
  end

  def handle_event("create_product", %{"product" => params}, socket) do
    attrs =
      %{
        code: params["code"],
        name: params["name"],
        description: presence(params["description"]),
        recognition_mode: String.to_existing_atom(params["recognition_mode"] || "point_in_time")
      }
      |> put_service_period_source(params["service_period_source"])

    case Catalog.create_product(socket.assigns.scope, attrs) do
      {:ok, product} ->
        {:noreply,
         socket
         |> put_flash(:info, "Product #{product.code} created.")
         |> assign(product_form: to_form(%{}, as: "product"))
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("deactivate_product", %{"id" => id}, socket) do
    with {:ok, product} <- Catalog.fetch_product(socket.assigns.scope, id),
         {:ok, _product} <- Catalog.deactivate_product(socket.assigns.scope, product) do
      {:noreply, socket |> put_flash(:info, "Product #{product.code} deactivated.") |> refresh()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  def handle_event("save_product_mapping", %{"mapping" => params}, socket) do
    with {:ok, product} <- Catalog.fetch_product(socket.assigns.scope, params["product_id"] || ""),
         {:ok, mapping} <-
           Catalog.upsert_product_erp_mapping(socket.assigns.scope, product, %{
             erp_connection_id: socket.assigns.connection.id,
             external_product_number: params["external_product_number"]
           }) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Product #{product.code} mapped to #{mapping.external_product_number}."
       )
       |> refresh()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp refresh(socket) do
    scope = socket.assigns.scope
    {:ok, products} = Catalog.list_products(scope)
    {:ok, plans} = Catalog.list_plans(scope)

    plans_with_versions =
      Enum.map(plans, fn plan ->
        {:ok, versions} = Catalog.list_plan_versions(scope, plan)
        {plan, versions}
      end)

    product_mappings =
      Map.new(products, fn product ->
        {:ok, mappings} = Catalog.list_product_erp_mappings(scope, product)
        {product.id, mappings}
      end)

    connection =
      case ERP.get_connection(scope) do
        {:ok, connection} -> connection
        {:error, :not_found} -> nil
      end

    assign(socket,
      products: products,
      plans: plans_with_versions,
      product_mappings: product_mappings,
      connection: connection
    )
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp put_service_period_source(attrs, source)
       when source in ["billing_period", "subscription_period", "explicit"] do
    Map.put(attrs, :service_period_source, String.to_existing_atom(source))
  end

  defp put_service_period_source(attrs, _source), do: attrs
end
