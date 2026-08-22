defmodule BillingCoreWeb.GraphQL.Resolvers.Catalog do
  @moduledoc """
  Product, plan, plan version, and discount resolvers (SPEC §14.5 catalog
  and discounts capability groups).
  """

  import Ecto.Query

  alias BillingCore.{Catalog, Repo, Scope}
  alias BillingCore.Catalog.{PlanVersion, PriceComponent, Product}
  alias BillingCoreWeb.GraphQL.{Authz, Errors, Pagination}

  ## Queries

  def product(_parent, %{id: id}, %{context: %{scope: scope}}) do
    unwrap(Catalog.fetch_product(scope, id))
  end

  def products(_parent, args, %{context: %{scope: scope}}) do
    if Authz.can_read?(scope) do
      Product
      |> where([p], p.team_id == ^Scope.team_id!(scope))
      |> Pagination.connection(args, :code)
      |> case do
        {:ok, connection} -> {:ok, connection}
        {:error, :invalid_page_size} -> page_size_error()
        {:error, :invalid_cursor} -> Errors.query_error("INVALID_CURSOR", "cursor is not valid")
      end
    else
      Errors.unauthorized()
    end
  end

  def plan(_parent, %{id: id}, %{context: %{scope: scope}}) do
    unwrap(Catalog.fetch_plan(scope, id))
  end

  def plan_version(_parent, %{id: id}, %{context: %{scope: scope}}) do
    with true <- Authz.can_read?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %PlanVersion{} = version <-
           Repo.get_by(PlanVersion, id: uuid, team_id: Scope.team_id!(scope)) do
      {:ok, version}
    else
      false -> Errors.unauthorized()
      _ -> Errors.not_found()
    end
  end

  @doc "Ordered components of a plan version (single read, team-scoped by parent)."
  def price_components(plan_version, _args, _resolution) do
    {:ok,
     Repo.all(
       from c in PriceComponent,
         where: c.plan_version_id == ^plan_version.id,
         order_by: [asc: c.ordinal]
     )}
  end

  def discount(_parent, %{id: id}, %{context: %{scope: scope}}) do
    unwrap(Catalog.fetch_discount(scope, id))
  end

  ## Mutations

  def create_product(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs =
      input
      |> Map.take([:code, :name, :description, :recognition_mode, :service_period_source])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Catalog.create_product(scope, attrs) do
      {:ok, product} -> {:ok, %{product: product, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  def create_plan(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    case Catalog.create_plan(scope, Map.take(input, [:code, :name])) do
      {:ok, plan} -> {:ok, %{plan: plan, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  @doc "Creates a draft plan version together with its components (one command)."
  def create_plan_version(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    version_attrs =
      input
      |> Map.take([:currency, :interval_unit, :interval_count, :billing_timing, :effective_from])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    with {:fetch, {:ok, plan}} <- {:fetch, Catalog.fetch_plan(scope, input.plan_id)},
         {:components, {:ok, components}} <-
           {:components, build_component_attrs(input.components)} do
      result =
        Repo.transaction(fn ->
          with {:ok, draft} <- Catalog.create_draft_plan_version(scope, plan, version_attrs),
               :ok <- add_components(scope, draft, components) do
            draft
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, draft} -> {:ok, %{plan_version: draft, client_mutation_id: cmid}}
        {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
      end
    else
      {:fetch, {:error, reason}} ->
        {:ok, Errors.business_error(reason, cmid)}

      {:components, {:error, code}} ->
        {:ok,
         Errors.validation(
           "INVALID_PRICING_DEFINITION",
           "component #{code} must set exactly one pricing model group",
           [%{path: ["components", code], code: "INVALID", message: "exactly one model group"}],
           cmid
         )}
    end
  end

  def publish_plan_version(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with true <- Authz.can_read?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(input.plan_version_id),
         %PlanVersion{} = version <-
           Repo.get_by(PlanVersion, id: uuid, team_id: Scope.team_id!(scope)) do
      case Catalog.publish_plan_version(scope, version) do
        {:ok, published} -> {:ok, %{plan_version: published, client_mutation_id: cmid}}
        {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
      end
    else
      false -> {:ok, Errors.authorization(cmid)}
      _ -> {:ok, Errors.business_error(:not_found, cmid)}
    end
  end

  ## Internals

  defp build_component_attrs(components) do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, acc} ->
      case pricing_definition_map(component.pricing_definition) do
        {:ok, definition} ->
          attrs =
            component
            |> Map.take([
              :code,
              :product_id,
              :proration_policy,
              :ordinal,
              :metric_code,
              :aggregation
            ])
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Map.new()
            |> Map.put(:pricing_definition, definition)

          {:cont, {:ok, [attrs | acc]}}

        :error ->
          {:halt, {:error, component.code}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  # Exactly one model group must be set (SPEC §9.6 versioned definitions).
  defp pricing_definition_map(input) do
    groups =
      [
        fixed_recurring: input[:fixed_recurring],
        one_time: input[:one_time],
        standard_metered: input[:standard_metered],
        volume_tier: input[:volume_tier],
        graduated_tier: input[:graduated_tier],
        package: input[:package],
        minimum_commit: input[:minimum_commit]
      ]
      |> Enum.reject(fn {_type, value} -> is_nil(value) end)

    case groups do
      [{type, value}] -> build_definition(type, value)
      _ambiguous -> :error
    end
  end

  defp build_definition(:fixed_recurring, %{unit_price: price}),
    do: {:ok, header("fixed_recurring") |> Map.put("unit_price", dec(price))}

  defp build_definition(:one_time, %{unit_price: price}),
    do: {:ok, header("one_time") |> Map.put("unit_price", dec(price))}

  defp build_definition(:standard_metered, %{unit_rate: rate}),
    do: {:ok, header("standard_metered") |> Map.put("unit_rate", dec(rate))}

  defp build_definition(:volume_tier, %{tiers: tiers}),
    do: {:ok, header("volume_tier") |> Map.put("tiers", Enum.map(tiers, &tier_map/1))}

  defp build_definition(:graduated_tier, %{tiers: tiers}),
    do: {:ok, header("graduated_tier") |> Map.put("tiers", Enum.map(tiers, &tier_map/1))}

  defp build_definition(:package, %{package_size: size, package_price: price}) do
    {:ok,
     header("package")
     |> Map.put("package_size", dec(size))
     |> Map.put("package_price", dec(price))}
  end

  defp build_definition(:minimum_commit, %{minimum_amount_minor: minimum, inner: inner}) do
    case pricing_definition_map(inner) do
      {:ok, inner_map} ->
        {:ok,
         header("minimum_commit")
         |> Map.put("minimum_amount_minor", minimum)
         |> Map.put("inner", inner_map)}

      :error ->
        :error
    end
  end

  defp tier_map(tier) do
    base = %{"from" => dec(tier.from), "unit_rate" => dec(tier.unit_rate)}
    base = if tier[:to], do: Map.put(base, "to", dec(tier.to)), else: base
    if tier[:flat_fee_minor], do: Map.put(base, "flat_fee_minor", tier.flat_fee_minor), else: base
  end

  defp header(type), do: %{"schema_version" => 1, "type" => type}
  defp dec(value), do: BillingCore.Domain.Canonical.decimal_string(value)

  defp add_components(scope, draft, components) do
    Enum.reduce_while(components, :ok, fn attrs, :ok ->
      case Catalog.add_price_component(scope, draft, attrs) do
        {:ok, _component} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, component_error(attrs, reason)}}
      end
    end)
  end

  defp component_error(attrs, {:invalid_pricing_definition, reasons}),
    do: {:invalid_pricing_definition, attrs[:code], reasons}

  defp component_error(_attrs, reason), do: reason

  defp unwrap(result) do
    case result do
      {:ok, value} -> {:ok, value}
      {:error, :unauthorized} -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  def map_product_to_erp(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, product} <- Catalog.fetch_product(scope, input.product_id),
         {:ok, mapping} <-
           Catalog.upsert_product_erp_mapping(scope, product, %{
             erp_connection_id: input.erp_connection_id,
             external_product_number: input.external_product_number
           }) do
      {:ok, %{mapping: mapping, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  defp page_size_error do
    Errors.query_error(
      "INVALID_PAGE_SIZE",
      "first must be between 1 and #{Pagination.max_page_size()}"
    )
  end
end
