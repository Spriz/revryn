defmodule BillingCoreWeb.CatalogLive.PlanVersion do
  @moduledoc """
  Plan-version detail: read-only rendering of the version's price components
  and pricing definitions, plus publication of drafts (BC-US-013/014).
  """

  use BillingCoreWeb, :live_view

  on_mount BillingCoreWeb.TeamScope

  alias BillingCore.Catalog
  alias BillingCoreWeb.LiveHelpers

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.team_nav team={@team} organization={@scope.organization} active={:catalog} />

      <.header>
        {@plan.name} · v{@plan_version.version}
        <:subtitle>
          <span class="font-mono">{@plan.code}</span>
          · {@plan_version.currency} · every {@plan_version.interval_count} {@plan_version.interval_unit}(s)
          · {@plan_version.billing_timing}
          <.state_badge state={@plan_version.status} class="ml-1" />
        </:subtitle>
        <:actions>
          <.button
            :if={@plan_version.status == :draft}
            id="publish-plan-version"
            variant="primary"
            phx-click="publish"
            phx-disable-with="Publishing…"
            data-confirm="Publish this version? Published versions are immutable."
          >
            Publish
          </.button>
        </:actions>
      </.header>

      <p :if={@plan_version.published_at} class="text-sm opacity-70">
        Published {format_dt(@plan_version.published_at)}
        <span :if={@plan_version.content_hash}>
          · content hash <.hash value={@plan_version.content_hash} />
        </span>
      </p>

      <section class="mt-6 space-y-4">
        <h2 class="text-lg font-semibold">Price components</h2>

        <.empty_state :if={@components == []} id="no-components">
          This version has no price components yet — drafts need at least one to publish.
        </.empty_state>

        <div
          :for={component <- @components}
          id={"component-#{component.id}"}
          class="rounded-lg border border-base-300 p-4"
        >
          <p class="font-medium">
            <span class="font-mono">{component.code}</span>
            <span class="ml-2 badge badge-ghost badge-sm">{component.pricing_model}</span>
          </p>
          <dl class="mt-2 grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
            <div class="flex gap-2">
              <dt class="opacity-60">Product</dt>
              <dd>{product_label(@products_by_id, component)}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="opacity-60">Recognition</dt>
              <dd>
                {component.recognition_mode}
                <span :if={component.service_period_source}>
                  ({component.service_period_source})
                </span>
              </dd>
            </div>
            <div class="flex gap-2">
              <dt class="opacity-60">Proration</dt>
              <dd>{component.proration_policy}</dd>
            </div>
            <div class="flex gap-2">
              <dt class="opacity-60">Rendering</dt>
              <dd>{component.rendering_policy}</dd>
            </div>
            <div :if={component.metric_code} class="flex gap-2">
              <dt class="opacity-60">Metric</dt>
              <dd>{component.metric_code} ({component.aggregation})</dd>
            </div>
          </dl>
          <div class="mt-2">
            <.trace
              id={"component-#{component.id}-definition"}
              trace={component.pricing_definition}
              label="Pricing definition"
            />
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  def mount(%{"id" => id}, _session, socket) do
    case Catalog.get_plan_version(socket.assigns.scope, id) do
      {:ok, plan_version} ->
        {:ok, plan} = Catalog.fetch_plan(socket.assigns.scope, plan_version.plan_id)

        {:ok,
         socket
         |> assign(plan: plan, page_title: "#{plan.code} v#{plan_version.version}")
         |> load(plan_version)}

      {:error, _reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Plan version not found.")
         |> push_navigate(to: ~p"/teams/#{socket.assigns.team.id}/catalog")}
    end
  end

  def handle_event("publish", _params, socket) do
    case Catalog.publish_plan_version(socket.assigns.scope, socket.assigns.plan_version) do
      {:ok, published} ->
        {:noreply,
         socket
         |> put_flash(:info, "Version v#{published.version} published.")
         |> load(published)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, LiveHelpers.error_message(reason))}
    end
  end

  defp load(socket, plan_version) do
    {:ok, components} = Catalog.list_price_components(socket.assigns.scope, plan_version)

    products_by_id =
      components
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()
      |> Map.new(fn product_id ->
        case Catalog.fetch_product(socket.assigns.scope, product_id) do
          {:ok, product} -> {product_id, product}
          {:error, _} -> {product_id, nil}
        end
      end)

    assign(socket,
      plan_version: plan_version,
      components: components,
      products_by_id: products_by_id
    )
  end

  defp product_label(products_by_id, component) do
    case Map.get(products_by_id, component.product_id) do
      %{code: code, name: name} -> "#{name} (#{code}, v#{component.product_version})"
      _missing -> "v#{component.product_version}"
    end
  end
end
