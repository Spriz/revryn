defmodule BillingCore.Catalog do
  @moduledoc """
  Product, plan, and discount catalog (SPEC §8.2 Epic B, §8.7
  BC-US-060/061/062, §13.3).

  Aggregates own stable team-scoped codes; content lives in immutable
  versions:

    * products — mutable head + append-only `product_versions` snapshots of
      the accountant-approved recognition policy (BC-US-010/011);
    * plans — draft `plan_versions` are mutable/deletable, publication
      freezes them (database-enforced) and pins subscriptions to their
      assigned version (BC-US-013/014);
    * discounts — append-only `discount_versions`, attached to a contract or
      subscription through `discount_assignments` which are deactivated
      prospectively, never rewritten (BC-US-060/061/062).

  Every price component's `pricing_definition` is validated with
  `BillingCore.Pricing.Model.from_map/1` the moment it enters the catalog
  and stored in the canonical `to_map/1` form; publication re-validates all
  components. A price component has no currency of its own — its amounts
  are denominated in the plan version's currency.

  Authorization: all functions take a team-resolved `BillingCore.Scope`
  first. Mutations require `billing_admin` or `team_admin`; ERP mapping
  writes require `finance_operator`; reads allow every team role. Queries
  are constrained by `Scope.team_id!/1`.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Outbox, Repo, Scope}

  alias BillingCore.Catalog.{
    Discount,
    DiscountAssignment,
    DiscountVersion,
    Plan,
    PlanVersion,
    PriceComponent,
    Product,
    ProductErpMapping,
    ProductVersion
  }

  alias BillingCore.Domain.Canonical
  alias BillingCore.Pricing.Model

  @mutation_roles [:billing_admin, :team_admin]
  @erp_write_roles [:finance_operator]
  @read_roles [:team_admin, :billing_admin, :finance_operator, :auditor, :integration_client]

  ## Products

  @doc """
  Creates a product together with its immutable version 1 snapshot
  (BC-US-010/011).

  `attrs`: `:code`, `:name` (required), `:description`, and the default
  recognition policy — `:recognition_mode` (defaults to `:point_in_time`),
  `:service_period_source` (required for `:over_time`),
  `:approver_reference`, `:approved_at`, `:evidence_reference`.

  Emits `product.version_created.v1`.
  """
  @spec create_product(Scope.t(), map() | keyword()) ::
          {:ok, Product.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_product(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, @mutation_roles) do
      changeset =
        Product.create_changeset(
          %Product{team_id: Scope.team_id!(scope), current_version: 1},
          Map.new(attrs)
        )

      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, product} ->
            record_product_version!(scope, product, 1)

            Audit.record!(scope, "catalog.product.created",
              aggregate: {"product", product.id},
              payload: %{code: product.code}
            )

            product

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Updates a product by appending a new immutable product version and moving
  the head (BC-US-011: changing policy creates a new version; it never
  rewrites history).

  The code is immutable once any price component references the product
  (`{:error, :code_immutable}`). Emits `product.version_created.v1`.
  """
  @spec update_product(Scope.t(), Product.t(), map() | keyword()) ::
          {:ok, Product.t()}
          | {:error, :unauthorized | :code_immutable | Ecto.Changeset.t()}
  def update_product(%Scope{} = scope, %Product{} = product, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, product) do
      attrs = Map.new(attrs)

      Repo.transaction(fn ->
        product = lock_product!(scope, product.id)
        changeset = Product.update_changeset(product, attrs)
        new_code = Ecto.Changeset.get_field(changeset, :code)

        if new_code != product.code and product_referenced?(product.id) do
          Repo.rollback(:code_immutable)
        end

        new_version = product.current_version + 1
        changeset = Ecto.Changeset.put_change(changeset, :current_version, new_version)

        case Repo.update(changeset) do
          {:ok, updated} ->
            record_product_version!(scope, updated, new_version)
            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Deactivates a product: publication of plans using it is blocked, but all
  historical versions stay valid (BC-US-010). Idempotent.
  """
  @spec deactivate_product(Scope.t(), Product.t()) ::
          {:ok, Product.t()} | {:error, :unauthorized}
  def deactivate_product(%Scope{} = scope, %Product{} = product) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, product) do
      Repo.transaction(fn ->
        product = lock_product!(scope, product.id)

        if product.status == :inactive do
          product
        else
          deactivated =
            product |> Ecto.Changeset.change(status: :inactive) |> Repo.update!()

          Audit.record!(scope, "catalog.product.deactivated",
            aggregate: {"product", product.id},
            payload: %{code: product.code}
          )

          deactivated
        end
      end)
    end
  end

  @doc "Fetches a team product by ID."
  @spec fetch_product(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Product.t()} | {:error, :unauthorized | :not_found}
  def fetch_product(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(Product, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        product -> {:ok, product}
      end
    end
  end

  @doc "Lists the team's products ordered by code."
  @spec list_products(Scope.t()) :: {:ok, [Product.t()]} | {:error, :unauthorized}
  def list_products(%Scope{} = scope) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.all(
         from p in Product,
           where: p.team_id == ^Scope.team_id!(scope),
           order_by: [asc: p.code]
       )}
    end
  end

  @doc "Lists a product's immutable versions in ascending order."
  @spec list_product_versions(Scope.t(), Product.t()) ::
          {:ok, [ProductVersion.t()]} | {:error, :unauthorized}
  def list_product_versions(%Scope{} = scope, %Product{} = product) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- same_team(scope, product) do
      {:ok,
       Repo.all(
         from v in ProductVersion,
           where: v.team_id == ^Scope.team_id!(scope) and v.product_id == ^product.id,
           order_by: [asc: v.version]
       )}
    end
  end

  ## Product ERP mappings

  @doc """
  Stores (or replaces) the mapping of `product` to an ERP product number
  with `validation_status: :pending` (BC-US-012).

  Provider validation is the ERP context's job — it validates the mapping
  and emits `product.erp_mapping_validated.v1`; the catalog only persists
  and unique-enforces. Upserts on `(team, erp_connection, product)`; a
  number already mapped to another product yields a changeset error.

  Requires the `finance_operator` role.
  """
  @spec upsert_product_erp_mapping(Scope.t(), Product.t(), map() | keyword()) ::
          {:ok, ProductErpMapping.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def upsert_product_erp_mapping(%Scope{} = scope, %Product{} = product, attrs) do
    with :ok <- authorize(scope, @erp_write_roles),
         :ok <- same_team(scope, product) do
      changeset =
        ProductErpMapping.changeset(
          %ProductErpMapping{team_id: Scope.team_id!(scope), product_id: product.id},
          Map.new(attrs)
        )

      Repo.transaction(fn ->
        case Repo.insert(changeset,
               on_conflict:
                 {:replace,
                  [
                    :external_product_number,
                    :validation_status,
                    :external_snapshot,
                    :external_snapshot_hash,
                    :validated_at,
                    :updated_at
                  ]},
               conflict_target: [:team_id, :erp_connection_id, :product_id],
               returning: true
             ) do
          {:ok, mapping} ->
            Audit.record!(scope, "catalog.product_erp_mapping.upserted",
              aggregate: {"product_erp_mapping", mapping.id},
              payload: %{
                product_id: product.id,
                erp_connection_id: mapping.erp_connection_id,
                external_product_number: mapping.external_product_number
              }
            )

            mapping

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "Lists the ERP mappings of a product."
  @spec list_product_erp_mappings(Scope.t(), Product.t()) ::
          {:ok, [ProductErpMapping.t()]} | {:error, :unauthorized}
  def list_product_erp_mappings(%Scope{} = scope, %Product{} = product) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- same_team(scope, product) do
      {:ok,
       Repo.all(
         from m in ProductErpMapping,
           where: m.team_id == ^Scope.team_id!(scope) and m.product_id == ^product.id,
           order_by: [asc: m.created_at]
       )}
    end
  end

  @doc "Fetches one ERP mapping by ID."
  @spec get_product_erp_mapping(Scope.t(), Ecto.UUID.t()) ::
          {:ok, ProductErpMapping.t()} | {:error, :unauthorized | :not_found}
  def get_product_erp_mapping(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(ProductErpMapping, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        mapping -> {:ok, mapping}
      end
    end
  end

  ## Plans

  @doc "Creates a plan (stable code owner, no versions yet — BC-US-013)."
  @spec create_plan(Scope.t(), map() | keyword()) ::
          {:ok, Plan.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_plan(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, @mutation_roles) do
      changeset =
        Plan.create_changeset(%Plan{team_id: Scope.team_id!(scope)}, Map.new(attrs))

      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, plan} ->
            Audit.record!(scope, "catalog.plan.created",
              aggregate: {"plan", plan.id},
              payload: %{code: plan.code}
            )

            plan

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "Fetches a team plan by ID."
  @spec fetch_plan(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Plan.t()} | {:error, :unauthorized | :not_found}
  def fetch_plan(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(Plan, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        plan -> {:ok, plan}
      end
    end
  end

  @doc "Lists the team's plans ordered by code."
  @spec list_plans(Scope.t()) :: {:ok, [Plan.t()]} | {:error, :unauthorized}
  def list_plans(%Scope{} = scope) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.all(
         from p in Plan,
           where: p.team_id == ^Scope.team_id!(scope),
           order_by: [asc: p.code]
       )}
    end
  end

  @doc "Lists a plan's versions in ascending version order."
  @spec list_plan_versions(Scope.t(), Plan.t()) ::
          {:ok, [PlanVersion.t()]} | {:error, :unauthorized}
  def list_plan_versions(%Scope{} = scope, %Plan{} = plan) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- same_team(scope, plan) do
      {:ok,
       Repo.all(
         from v in PlanVersion,
           where: v.team_id == ^Scope.team_id!(scope) and v.plan_id == ^plan.id,
           order_by: [asc: v.version]
       )}
    end
  end

  @doc "Fetches a team plan version by ID in any status (draft included)."
  @spec get_plan_version(Scope.t(), Ecto.UUID.t()) ::
          {:ok, PlanVersion.t()} | {:error, :unauthorized | :not_found}
  def get_plan_version(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(PlanVersion, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        plan_version -> {:ok, plan_version}
      end
    end
  end

  @doc "Price components of a plan version in ordinal order."
  @spec list_price_components(Scope.t(), PlanVersion.t()) ::
          {:ok, [PriceComponent.t()]} | {:error, :unauthorized}
  def list_price_components(%Scope{} = scope, %PlanVersion{} = plan_version) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- same_team(scope, plan_version) do
      {:ok,
       Repo.all(
         from c in PriceComponent,
           where:
             c.team_id == ^Scope.team_id!(scope) and
               c.plan_version_id == ^plan_version.id,
           order_by: [asc: c.ordinal]
       )}
    end
  end

  @doc """
  Creates the next draft plan version (version = highest existing + 1,
  BC-US-013).

  `attrs`: `:currency`, `:interval_unit` (`:month`/`:day`),
  `:interval_count`, `:billing_timing` (`:in_advance`/`:in_arrears`),
  optional `:effective_from`. Whole-month counts are limited to
  1/2/3/4/6/12 (SPEC §9.5).
  """
  @spec create_draft_plan_version(Scope.t(), Plan.t(), map() | keyword()) ::
          {:ok, PlanVersion.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_draft_plan_version(%Scope{} = scope, %Plan{} = plan, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, plan) do
      attrs = Map.new(attrs)

      Repo.transaction(fn ->
        plan = lock_plan!(scope, plan.id)

        max_version =
          Repo.one(
            from v in PlanVersion,
              where: v.plan_id == ^plan.id,
              select: max(v.version)
          ) || 0

        changeset =
          PlanVersion.draft_changeset(
            %PlanVersion{
              team_id: plan.team_id,
              plan_id: plan.id,
              version: max_version + 1,
              status: :draft
            },
            attrs
          )

        case Repo.insert(changeset) do
          {:ok, plan_version} ->
            Audit.record!(scope, "catalog.plan_version.draft_created",
              aggregate: {"plan", plan.id},
              payload: %{plan_version_id: plan_version.id, version: plan_version.version}
            )

            plan_version

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Updates a draft plan version's billing fields. Published versions return
  `{:error, :published_immutable}` (BC-US-014).
  """
  @spec update_draft_plan_version(Scope.t(), PlanVersion.t(), map() | keyword()) ::
          {:ok, PlanVersion.t()}
          | {:error, :unauthorized | :published_immutable | Ecto.Changeset.t()}
  def update_draft_plan_version(%Scope{} = scope, %PlanVersion{} = plan_version, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, plan_version) do
      attrs = Map.new(attrs)

      Repo.transaction(fn ->
        plan_version = lock_plan_version!(scope, plan_version.id)

        if plan_version.status != :draft, do: Repo.rollback(:published_immutable)

        case Repo.update(PlanVersion.draft_changeset(plan_version, attrs)) do
          {:ok, updated} ->
            Audit.record!(scope, "catalog.plan_version.draft_updated",
              aggregate: {"plan", updated.plan_id},
              payload: %{plan_version_id: updated.id, version: updated.version}
            )

            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Deletes a draft plan version and its components (BC-US-013: drafts may be
  deleted before publication). Non-drafts return
  `{:error, :published_immutable}`.
  """
  @spec delete_draft_plan_version(Scope.t(), PlanVersion.t()) ::
          {:ok, PlanVersion.t()} | {:error, :unauthorized | :published_immutable}
  def delete_draft_plan_version(%Scope{} = scope, %PlanVersion{} = plan_version) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, plan_version) do
      Repo.transaction(fn ->
        plan_version = lock_plan_version!(scope, plan_version.id)

        if plan_version.status != :draft, do: Repo.rollback(:published_immutable)

        deleted = Repo.delete!(plan_version)

        Audit.record!(scope, "catalog.plan_version.draft_deleted",
          aggregate: {"plan", deleted.plan_id},
          payload: %{plan_version_id: deleted.id, version: deleted.version}
        )

        deleted
      end)
    end
  end

  ## Price components

  @doc """
  Adds a price component to a draft plan version (BC-US-013/015…021).

  `attrs`: `:code`, `:product_id`, `:pricing_definition` (required — a
  `schema_version: 1` map validated immediately with
  `BillingCore.Pricing.Model.from_map/1`; failures return
  `{:error, {:invalid_pricing_definition, reasons}}`), optional
  `:product_version` (defaults to the product's current version),
  `:recognition_mode`/`:service_period_source` (default from the product's
  policy), `:proration_policy`, `:rendering_policy`, `:metric_code` +
  `:aggregation` (required for usage-based models), `:ordinal` (defaults to
  the next free ordinal).

  The stored `pricing_definition` is the canonical
  `BillingCore.Pricing.Model.to_map/1` form.
  """
  @spec add_price_component(Scope.t(), PlanVersion.t(), map() | keyword()) ::
          {:ok, PriceComponent.t()}
          | {:error,
             :unauthorized
             | :published_immutable
             | :product_not_found
             | {:invalid_pricing_definition, [term()]}
             | Ecto.Changeset.t()}
  def add_price_component(%Scope{} = scope, %PlanVersion{} = plan_version, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, plan_version) do
      attrs = Map.new(attrs)

      Repo.transaction(fn ->
        plan_version = lock_plan_version!(scope, plan_version.id)

        if plan_version.status != :draft, do: Repo.rollback(:published_immutable)

        product =
          case attrs[:product_id] do
            nil ->
              Repo.rollback(:product_not_found)

            product_id ->
              Repo.get_by(Product, id: product_id, team_id: Scope.team_id!(scope)) ||
                Repo.rollback(:product_not_found)
          end

        {pricing_model, canonical_definition} =
          parse_pricing_definition!(Map.fetch(attrs, :pricing_definition))

        attrs =
          attrs
          |> Map.put(:pricing_model, pricing_model)
          |> Map.put(:pricing_definition, canonical_definition)
          |> Map.put_new(:product_version, product.current_version)
          |> default_recognition_from(product)
          |> Map.put_new_lazy(:ordinal, fn -> next_ordinal(plan_version.id) end)

        changeset =
          PriceComponent.changeset(
            %PriceComponent{
              team_id: plan_version.team_id,
              plan_version_id: plan_version.id
            },
            attrs
          )

        case Repo.insert(changeset) do
          {:ok, component} ->
            Audit.record!(scope, "catalog.price_component.added",
              aggregate: {"plan", plan_version.plan_id},
              payload: %{
                plan_version_id: plan_version.id,
                price_component_id: component.id,
                code: component.code,
                pricing_model: component.pricing_model
              }
            )

            component

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Updates a price component of a draft plan version. A supplied
  `:pricing_definition` is re-validated immediately; published plan versions
  return `{:error, :published_immutable}`.
  """
  @spec update_price_component(Scope.t(), PriceComponent.t(), map() | keyword()) ::
          {:ok, PriceComponent.t()}
          | {:error,
             :unauthorized
             | :published_immutable
             | {:invalid_pricing_definition, [term()]}
             | Ecto.Changeset.t()}
  def update_price_component(%Scope{} = scope, %PriceComponent{} = component, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, component) do
      attrs = Map.new(attrs)

      Repo.transaction(fn ->
        component = Repo.get!(PriceComponent, component.id)
        plan_version = lock_plan_version!(scope, component.plan_version_id)

        if plan_version.status != :draft, do: Repo.rollback(:published_immutable)

        attrs =
          case Map.fetch(attrs, :pricing_definition) do
            :error ->
              attrs

            {:ok, _definition} = fetched ->
              {pricing_model, canonical_definition} = parse_pricing_definition!(fetched)

              attrs
              |> Map.put(:pricing_model, pricing_model)
              |> Map.put(:pricing_definition, canonical_definition)
          end

        case Repo.update(PriceComponent.changeset(component, attrs)) do
          {:ok, updated} ->
            Audit.record!(scope, "catalog.price_component.updated",
              aggregate: {"plan", plan_version.plan_id},
              payload: %{
                plan_version_id: plan_version.id,
                price_component_id: updated.id,
                code: updated.code
              }
            )

            updated

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "Removes a price component from a draft plan version."
  @spec remove_price_component(Scope.t(), PriceComponent.t()) ::
          {:ok, PriceComponent.t()} | {:error, :unauthorized | :published_immutable}
  def remove_price_component(%Scope{} = scope, %PriceComponent{} = component) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, component) do
      Repo.transaction(fn ->
        component = Repo.get!(PriceComponent, component.id)
        plan_version = lock_plan_version!(scope, component.plan_version_id)

        if plan_version.status != :draft, do: Repo.rollback(:published_immutable)

        deleted = Repo.delete!(component)

        Audit.record!(scope, "catalog.price_component.removed",
          aggregate: {"plan", plan_version.plan_id},
          payload: %{
            plan_version_id: plan_version.id,
            price_component_id: deleted.id,
            code: deleted.code
          }
        )

        deleted
      end)
    end
  end

  ## Publication

  @doc """
  Publishes a draft plan version (BC-US-014).

  Validation: at least one component; every component's product is active
  and its pinned product version exists; every pricing definition parses
  with `BillingCore.Pricing.Model.from_map/1`; over-time components carry a
  service-period source (SPEC §9.4). Component amounts are denominated in
  the plan version's currency by construction.

  On success the version becomes immutable (database trigger), `definition`
  holds the canonical publication snapshot, `content_hash` its canonical
  SHA-256, and `plans.current_version` is bumped — existing subscriptions
  stay pinned to their assigned version. Emits `plan.version_published.v1`.
  """
  @spec publish_plan_version(Scope.t(), PlanVersion.t()) ::
          {:ok, PlanVersion.t()}
          | {:error,
             :unauthorized
             | :not_draft
             | :no_components
             | {:product_inactive, String.t()}
             | {:missing_product_version, String.t()}
             | {:missing_service_period_source, String.t()}
             | {:invalid_pricing_definition, String.t(), [term()]}}
  def publish_plan_version(%Scope{} = scope, %PlanVersion{} = plan_version) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, plan_version) do
      Repo.transaction(fn ->
        plan = lock_plan!(scope, plan_version.plan_id)
        plan_version = lock_plan_version!(scope, plan_version.id)

        if plan_version.status != :draft, do: Repo.rollback(:not_draft)

        components = ordered_components(plan_version.id)

        if components == [], do: Repo.rollback(:no_components)

        component_maps = Enum.map(components, &validated_component_map!(scope, &1))

        definition = %{
          "schema_version" => 1,
          "plan_code" => plan.code,
          "plan_name" => plan.name,
          "version" => plan_version.version,
          "currency" => plan_version.currency,
          "interval_unit" => Atom.to_string(plan_version.interval_unit),
          "interval_count" => plan_version.interval_count,
          "billing_timing" => Atom.to_string(plan_version.billing_timing),
          "effective_from" =>
            plan_version.effective_from && Date.to_iso8601(plan_version.effective_from),
          "components" => component_maps
        }

        content_hash = Canonical.hash(definition)

        published =
          plan_version
          |> Ecto.Changeset.change(
            status: :published,
            published_at: DateTime.utc_now(),
            published_by: actor_user_id(scope),
            definition: definition,
            content_hash: content_hash
          )
          |> Repo.update!()

        plan
        |> Ecto.Changeset.change(current_version: max(plan.current_version, published.version))
        |> Repo.update!()

        Audit.record!(scope, "catalog.plan_version.published",
          aggregate: {"plan", plan.id},
          payload: %{
            plan_version_id: published.id,
            version: published.version,
            content_hash: content_hash
          }
        )

        Outbox.emit!("plan.version_published.v1",
          aggregate: {"plan", plan.id},
          aggregate_version: published.version,
          team_id: plan.team_id,
          correlation_id: scope.correlation_id,
          payload: %{
            plan_id: plan.id,
            plan_version_id: published.id,
            code: plan.code,
            version: published.version,
            currency: published.currency,
            content_hash: content_hash
          }
        )

        published
      end)
    end
  end

  @doc """
  Retires a published plan version. The database permits only this
  transition on published rows; the row otherwise stays frozen.
  """
  @spec retire_plan_version(Scope.t(), PlanVersion.t()) ::
          {:ok, PlanVersion.t()} | {:error, :unauthorized | :not_published}
  def retire_plan_version(%Scope{} = scope, %PlanVersion{} = plan_version) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, plan_version) do
      Repo.transaction(fn ->
        plan_version = lock_plan_version!(scope, plan_version.id)

        if plan_version.status != :published, do: Repo.rollback(:not_published)

        retired =
          plan_version |> Ecto.Changeset.change(status: :retired) |> Repo.update!()

        Audit.record!(scope, "catalog.plan_version.retired",
          aggregate: {"plan", retired.plan_id},
          payload: %{plan_version_id: retired.id, version: retired.version}
        )

        retired
      end)
    end
  end

  @doc "Fetches a published plan version with its components (ordered)."
  @spec get_published_plan_version(Scope.t(), Ecto.UUID.t()) ::
          {:ok, PlanVersion.t()} | {:error, :unauthorized | :not_found}
  def get_published_plan_version(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      components_query =
        from c in PriceComponent, order_by: [asc: c.ordinal, asc: c.code]

      plan_version =
        Repo.one(
          from v in PlanVersion,
            where:
              v.id == ^id and v.team_id == ^Scope.team_id!(scope) and
                v.status == :published,
            preload: [price_components: ^components_query]
        )

      case plan_version do
        nil -> {:error, :not_found}
        plan_version -> {:ok, plan_version}
      end
    end
  end

  @doc """
  Parses every component's stored pricing definition back into its
  `BillingCore.Pricing.Model` struct.

  Published catalog data must always parse — corruption raises rather than
  returning an error tuple.
  """
  @spec fetch_pricing_models(PlanVersion.t()) :: {:ok, [{PriceComponent.t(), Model.t()}]}
  def fetch_pricing_models(%PlanVersion{} = plan_version) do
    components =
      case plan_version.price_components do
        %Ecto.Association.NotLoaded{} -> ordered_components(plan_version.id)
        components -> components
      end

    pairs =
      Enum.map(components, fn component ->
        case Model.from_map(component.pricing_definition) do
          {:ok, model} ->
            {component, model}

          {:error, reasons} ->
            raise "corrupt pricing definition on price component " <>
                    "#{component.id} (#{component.code}): #{inspect(reasons)}"
        end
      end)

    {:ok, pairs}
  end

  ## Discounts

  @doc "Creates a discount (stable code owner, no versions yet — BC-US-060)."
  @spec create_discount(Scope.t(), map() | keyword()) ::
          {:ok, Discount.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_discount(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, @mutation_roles) do
      changeset =
        Discount.create_changeset(%Discount{team_id: Scope.team_id!(scope)}, Map.new(attrs))

      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, discount} ->
            Audit.record!(scope, "catalog.discount.created",
              aggregate: {"discount", discount.id},
              payload: %{code: discount.code}
            )

            discount

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Publishes the next immutable discount version (BC-US-060/061/062).

  `attrs`: `:discount_type` (`:percentage` with `:basis_points` 1..10000,
  or `:fixed_amount` with `:amount_minor` > 0 and `:currency` — exactly one
  group), `:eligible_scope` (`%{"all" => true}` or product/component code
  lists, default all), `:priority` (required), `:effective_from`
  (required), `:effective_until_exclusive`, `:max_billing_periods`,
  `:allocation_policy` (default `"proportional"`).

  Emits `discount.version_published.v1`.
  """
  @spec publish_discount_version(Scope.t(), Discount.t(), map() | keyword()) ::
          {:ok, DiscountVersion.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def publish_discount_version(%Scope{} = scope, %Discount{} = discount, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, discount) do
      attrs = Map.new(attrs)

      Repo.transaction(fn ->
        discount = lock_discount!(scope, discount.id)
        version = discount.current_version + 1

        changeset =
          DiscountVersion.changeset(
            %DiscountVersion{
              team_id: discount.team_id,
              discount_id: discount.id,
              version: version
            },
            attrs
          )

        changeset =
          if changeset.valid? do
            Ecto.Changeset.put_change(
              changeset,
              :content_hash,
              Canonical.hash(discount_definition(changeset, discount, version))
            )
          else
            changeset
          end

        case Repo.insert(changeset) do
          {:ok, discount_version} ->
            discount
            |> Ecto.Changeset.change(current_version: version)
            |> Repo.update!()

            Audit.record!(scope, "catalog.discount_version.published",
              aggregate: {"discount", discount.id},
              payload: %{
                discount_version_id: discount_version.id,
                version: version,
                content_hash: discount_version.content_hash
              }
            )

            Outbox.emit!("discount.version_published.v1",
              aggregate: {"discount", discount.id},
              aggregate_version: version,
              team_id: discount.team_id,
              correlation_id: scope.correlation_id,
              payload: %{
                discount_id: discount.id,
                discount_version_id: discount_version.id,
                code: discount.code,
                version: version,
                content_hash: discount_version.content_hash
              }
            )

            discount_version

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "Fetches a team discount by ID."
  @spec fetch_discount(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Discount.t()} | {:error, :unauthorized | :not_found}
  def fetch_discount(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(Discount, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        discount -> {:ok, discount}
      end
    end
  end

  @doc """
  Attaches an immutable discount version to exactly one contract or
  subscription for an effective interval (SPEC §13.3
  `discount_assignments`).

  `attrs`: exactly one of `:contract_id`/`:subscription_id`, plus
  `:effective_from` (required) and `:effective_until_exclusive`.
  Emits `discount.assignment_changed.v1`.
  """
  @spec assign_discount(Scope.t(), DiscountVersion.t(), map() | keyword()) ::
          {:ok, DiscountAssignment.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def assign_discount(%Scope{} = scope, %DiscountVersion{} = discount_version, attrs) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, discount_version) do
      changeset =
        DiscountAssignment.create_changeset(
          %DiscountAssignment{
            team_id: discount_version.team_id,
            discount_version_id: discount_version.id
          },
          Map.new(attrs)
        )

      Repo.transaction(fn ->
        case Repo.insert(changeset) do
          {:ok, assignment} ->
            Audit.record!(scope, "catalog.discount_assignment.created",
              aggregate: {"discount_assignment", assignment.id},
              payload: assignment_payload(assignment)
            )

            emit_assignment_changed!(scope, assignment)
            assignment

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  Deactivates an assignment prospectively: sets status `deactivated` and
  shortens `effective_until_exclusive` to `until` (default: today). The row
  is never rewritten retroactively — `until` may not lie in the past, may
  not precede `effective_from`, and may not extend an existing end date.

  Emits `discount.assignment_changed.v1`.
  """
  @spec deactivate_assignment(Scope.t(), DiscountAssignment.t(), Date.t() | nil) ::
          {:ok, DiscountAssignment.t()}
          | {:error, :unauthorized | :not_active | :retroactive_deactivation | :invalid_interval}
  def deactivate_assignment(%Scope{} = scope, %DiscountAssignment{} = assignment, until \\ nil) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- same_team(scope, assignment) do
      until = until || Date.utc_today()

      Repo.transaction(fn ->
        assignment = Repo.get!(DiscountAssignment, assignment.id)

        cond do
          assignment.status != :active ->
            Repo.rollback(:not_active)

          Date.compare(until, Date.utc_today()) == :lt ->
            Repo.rollback(:retroactive_deactivation)

          Date.compare(until, assignment.effective_from) != :gt ->
            Repo.rollback(:invalid_interval)

          not is_nil(assignment.effective_until_exclusive) and
              Date.compare(until, assignment.effective_until_exclusive) == :gt ->
            Repo.rollback(:invalid_interval)

          true ->
            deactivated =
              assignment
              |> Ecto.Changeset.change(status: :deactivated, effective_until_exclusive: until)
              |> Repo.update!()

            Audit.record!(scope, "catalog.discount_assignment.deactivated",
              aggregate: {"discount_assignment", deactivated.id},
              payload: assignment_payload(deactivated)
            )

            emit_assignment_changed!(scope, deactivated)
            deactivated
        end
      end)
    end
  end

  @doc "Lists the assignments of a contract or subscription target."
  @spec list_discount_assignments(Scope.t(), keyword()) ::
          {:ok, [DiscountAssignment.t()]} | {:error, :unauthorized}
  def list_discount_assignments(%Scope{} = scope, filters \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      query =
        from a in DiscountAssignment,
          where: a.team_id == ^Scope.team_id!(scope),
          order_by: [asc: a.created_at]

      query =
        Enum.reduce(Keyword.take(filters, [:contract_id, :subscription_id]), query, fn
          {:contract_id, id}, query -> where(query, [a], a.contract_id == ^id)
          {:subscription_id, id}, query -> where(query, [a], a.subscription_id == ^id)
        end)

      {:ok, Repo.all(query)}
    end
  end

  ## Internal helpers — authorization

  defp authorize(%Scope{} = scope, roles) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, roles) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  # Possession of a struct never grants access (SPEC §13.4): the aggregate
  # must belong to the scope's team.
  defp same_team(%Scope{} = scope, %{team_id: team_id}) do
    if team_id == Scope.team_id!(scope), do: :ok, else: {:error, :unauthorized}
  end

  defp actor_user_id(%Scope{user: %{id: id}}), do: id
  defp actor_user_id(%Scope{}), do: nil

  ## Internal helpers — products

  defp lock_product!(scope, id) do
    Repo.one!(
      from p in Product,
        where: p.id == ^id and p.team_id == ^Scope.team_id!(scope),
        lock: "FOR UPDATE"
    )
  end

  defp product_referenced?(product_id) do
    Repo.exists?(from c in PriceComponent, where: c.product_id == ^product_id)
  end

  defp record_product_version!(%Scope{} = scope, %Product{} = product, version) do
    snapshot = product_snapshot(product, version)
    content_hash = Canonical.hash(snapshot)

    product_version =
      Repo.insert!(%ProductVersion{
        team_id: product.team_id,
        product_id: product.id,
        version: version,
        name: product.name,
        description: product.description,
        recognition_mode: product.recognition_mode,
        service_period_source: product.service_period_source,
        approver_reference: product.approver_reference,
        approved_at: product.approved_at,
        evidence_reference: product.evidence_reference,
        snapshot: snapshot,
        content_hash: content_hash
      })

    Audit.record!(scope, "catalog.product.version_created",
      aggregate: {"product", product.id},
      payload: %{version: version, content_hash: content_hash}
    )

    Outbox.emit!("product.version_created.v1",
      aggregate: {"product", product.id},
      aggregate_version: version,
      team_id: product.team_id,
      correlation_id: scope.correlation_id,
      payload: %{
        product_id: product.id,
        code: product.code,
        version: version,
        content_hash: content_hash
      }
    )

    product_version
  end

  defp product_snapshot(%Product{} = product, version) do
    %{
      "code" => product.code,
      "name" => product.name,
      "description" => product.description,
      "recognition_mode" => Atom.to_string(product.recognition_mode),
      "service_period_source" =>
        product.service_period_source && Atom.to_string(product.service_period_source),
      "approver_reference" => product.approver_reference,
      "approved_at" => product.approved_at && DateTime.to_iso8601(product.approved_at),
      "evidence_reference" => product.evidence_reference,
      "version" => version
    }
  end

  ## Internal helpers — plans

  defp lock_plan!(scope, id) do
    Repo.one!(
      from p in Plan,
        where: p.id == ^id and p.team_id == ^Scope.team_id!(scope),
        lock: "FOR UPDATE"
    )
  end

  defp lock_plan_version!(scope, id) do
    Repo.one!(
      from v in PlanVersion,
        where: v.id == ^id and v.team_id == ^Scope.team_id!(scope),
        lock: "FOR UPDATE"
    )
  end

  defp ordered_components(plan_version_id) do
    Repo.all(
      from c in PriceComponent,
        where: c.plan_version_id == ^plan_version_id,
        order_by: [asc: c.ordinal, asc: c.code]
    )
  end

  # An explicitly overridden recognition mode never silently inherits the
  # product's service-period source; full inheritance copies both.
  defp default_recognition_from(attrs, %Product{} = product) do
    case Map.fetch(attrs, :recognition_mode) do
      {:ok, _mode} ->
        attrs

      :error ->
        attrs
        |> Map.put(:recognition_mode, product.recognition_mode)
        |> Map.put_new(:service_period_source, product.service_period_source)
    end
  end

  defp next_ordinal(plan_version_id) do
    max =
      Repo.one(
        from c in PriceComponent,
          where: c.plan_version_id == ^plan_version_id,
          select: max(c.ordinal)
      ) || 0

    max + 1
  end

  defp parse_pricing_definition!(:error),
    do: Repo.rollback({:invalid_pricing_definition, [:missing_definition]})

  defp parse_pricing_definition!({:ok, definition}) do
    case Model.from_map(definition) do
      {:ok, model} -> {Model.type(model), Model.to_map(model)}
      {:error, reasons} -> Repo.rollback({:invalid_pricing_definition, reasons})
    end
  end

  # BC-US-014 publication validation for one component. Runs inside the
  # publish transaction; failures roll back with a component-tagged reason.
  defp validated_component_map!(scope, %PriceComponent{} = component) do
    product = Repo.get_by(Product, id: component.product_id, team_id: Scope.team_id!(scope))

    if is_nil(product) or product.status != :active do
      Repo.rollback({:product_inactive, component.code})
    end

    product_version =
      Repo.get_by(ProductVersion,
        product_id: component.product_id,
        version: component.product_version
      ) || Repo.rollback({:missing_product_version, component.code})

    model =
      case Model.from_map(component.pricing_definition) do
        {:ok, model} -> model
        {:error, reasons} -> Repo.rollback({:invalid_pricing_definition, component.code, reasons})
      end

    # Defense in depth: the schema and a database CHECK already enforce this
    # (SPEC §9.4 — over_time lines require a service period source).
    if component.recognition_mode == :over_time and is_nil(component.service_period_source) do
      Repo.rollback({:missing_service_period_source, component.code})
    end

    %{
      "code" => component.code,
      "product_id" => component.product_id,
      "product_code" => product.code,
      "product_version" => component.product_version,
      "product_version_hash" => product_version.content_hash,
      "pricing_model" => component.pricing_model,
      "pricing_definition" => Model.to_map(model),
      "recognition_mode" => Atom.to_string(component.recognition_mode),
      "service_period_source" =>
        component.service_period_source && Atom.to_string(component.service_period_source),
      "proration_policy" => Atom.to_string(component.proration_policy),
      "rendering_policy" => Atom.to_string(component.rendering_policy),
      "metric_code" => component.metric_code,
      "aggregation" => component.aggregation && Atom.to_string(component.aggregation),
      "ordinal" => component.ordinal
    }
  end

  ## Internal helpers — discounts

  defp lock_discount!(scope, id) do
    Repo.one!(
      from d in Discount,
        where: d.id == ^id and d.team_id == ^Scope.team_id!(scope),
        lock: "FOR UPDATE"
    )
  end

  defp discount_definition(changeset, %Discount{} = discount, version) do
    get = &Ecto.Changeset.get_field(changeset, &1)

    %{
      "schema_version" => 1,
      "discount_code" => discount.code,
      "version" => version,
      "discount_type" => Atom.to_string(get.(:discount_type)),
      "basis_points" => get.(:basis_points),
      "amount_minor" => get.(:amount_minor),
      "currency" => get.(:currency),
      "eligible_scope" => get.(:eligible_scope),
      "priority" => get.(:priority),
      "effective_from" => Date.to_iso8601(get.(:effective_from)),
      "effective_until_exclusive" =>
        get.(:effective_until_exclusive) && Date.to_iso8601(get.(:effective_until_exclusive)),
      "max_billing_periods" => get.(:max_billing_periods),
      "allocation_policy" => get.(:allocation_policy)
    }
  end

  defp assignment_payload(%DiscountAssignment{} = assignment) do
    %{
      discount_version_id: assignment.discount_version_id,
      contract_id: assignment.contract_id,
      subscription_id: assignment.subscription_id,
      status: assignment.status,
      effective_from: Date.to_iso8601(assignment.effective_from),
      effective_until_exclusive:
        assignment.effective_until_exclusive &&
          Date.to_iso8601(assignment.effective_until_exclusive)
    }
  end

  defp emit_assignment_changed!(%Scope{} = scope, %DiscountAssignment{} = assignment) do
    Outbox.emit!("discount.assignment_changed.v1",
      aggregate: {"discount_assignment", assignment.id},
      team_id: assignment.team_id,
      correlation_id: scope.correlation_id,
      payload: assignment_payload(assignment)
    )
  end
end
