defmodule BillingCore.CatalogFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Catalog` context.
  """

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Catalog, Orgs, Scope}

  @doc "A unique catalog code with the given prefix."
  def unique_code(prefix \\ "code"), do: "#{prefix}-#{System.unique_integer([:positive])}"

  @doc """
  A team-resolved scope whose user holds `roles` (default `[:billing_admin]`)
  in a freshly created organization/team.
  """
  def catalog_scope_fixture(roles \\ [:billing_admin]) do
    %{organization: organization, team: team} = organization_fixture()
    scope_with_roles(%{organization: organization, team: team}, roles)
  end

  @doc "A scope for a new user with `roles` on the same team as `scope`."
  def scope_with_roles(%Scope{} = scope, roles),
    do: scope_with_roles(%{organization: scope.organization, team: scope.team}, roles)

  def scope_with_roles(%{organization: organization, team: team}, roles) do
    user = user_fixture()
    organization_membership_fixture(organization, user, [:organization_member])
    team_membership_fixture(team, user, roles)
    {:ok, scope} = Orgs.resolve_scope(user, organization.id, team.id)
    scope
  end

  @doc "Creates a product via `Catalog.create_product/2`."
  def product_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:code, unique_code("prod"))
      |> Map.put_new(:name, "Product #{System.unique_integer([:positive])}")

    {:ok, product} = Catalog.create_product(scope, attrs)
    product
  end

  @doc "Creates a plan via `Catalog.create_plan/2`."
  def plan_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:code, unique_code("plan"))
      |> Map.put_new(:name, "Plan #{System.unique_integer([:positive])}")

    {:ok, plan} = Catalog.create_plan(scope, attrs)
    plan
  end

  @doc """
  Creates a draft plan version. Options: `:plan` (created otherwise),
  `:currency` (\"DKK\"), `:interval_unit` (`:month`), `:interval_count` (1),
  `:billing_timing` (`:in_advance`), `:effective_from`.
  """
  def draft_plan_version_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {plan, attrs} = Map.pop_lazy(attrs, :plan, fn -> plan_fixture(scope) end)

    attrs =
      attrs
      |> Map.put_new(:currency, "DKK")
      |> Map.put_new(:interval_unit, :month)
      |> Map.put_new(:interval_count, 1)
      |> Map.put_new(:billing_timing, :in_advance)

    {:ok, plan_version} = Catalog.create_draft_plan_version(scope, plan, attrs)
    plan_version
  end

  @doc "A valid `schema_version: 1` fixed recurring pricing definition."
  def fixed_recurring_definition(unit_price \\ "100") do
    %{"schema_version" => 1, "type" => "fixed_recurring", "unit_price" => unit_price}
  end

  @doc """
  Adds a fixed recurring component to a draft plan version. Options:
  `:product` (created otherwise), `:code`, `:amount` (\"100\"), plus any
  `Catalog.add_price_component/3` attrs.
  """
  def fixed_recurring_component_fixture(scope, plan_version, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {product, attrs} = Map.pop_lazy(attrs, :product, fn -> product_fixture(scope) end)
    {amount, attrs} = Map.pop(attrs, :amount, "100")

    attrs =
      attrs
      |> Map.put_new(:code, unique_code("comp"))
      |> Map.put_new(:product_id, product.id)
      |> Map.put_new(:pricing_definition, fixed_recurring_definition(amount))

    {:ok, component} = Catalog.add_price_component(scope, plan_version, attrs)
    component
  end

  @doc """
  Creates and publishes a plan version carrying one fixed recurring
  component. Options: `:plan`, `:product`, `:currency`, `:interval_unit`,
  `:interval_count`, `:billing_timing`, `:effective_from`, `:amount`,
  `:component_code`.
  """
  def published_plan_version_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {product, attrs} = Map.pop_lazy(attrs, :product, fn -> product_fixture(scope) end)
    {amount, attrs} = Map.pop(attrs, :amount, "100")
    {component_code, attrs} = Map.pop_lazy(attrs, :component_code, fn -> unique_code("comp") end)

    draft = draft_plan_version_fixture(scope, attrs)

    fixed_recurring_component_fixture(scope, draft,
      product: product,
      amount: amount,
      code: component_code
    )

    {:ok, published} = Catalog.publish_plan_version(scope, draft)
    published
  end

  @doc "Creates a discount via `Catalog.create_discount/2`."
  def discount_fixture(scope, attrs \\ %{}) do
    attrs = attrs |> Map.new() |> Map.put_new(:code, unique_code("disc"))
    {:ok, discount} = Catalog.create_discount(scope, attrs)
    discount
  end

  @doc """
  Publishes a percentage discount version (default 10%, priority 100,
  effective today). Option `:discount` reuses an existing discount.
  """
  def percentage_discount_version_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {discount, attrs} = Map.pop_lazy(attrs, :discount, fn -> discount_fixture(scope) end)

    attrs =
      attrs
      |> Map.put_new(:discount_type, :percentage)
      |> Map.put_new(:basis_points, 1000)
      |> Map.put_new(:priority, 100)
      |> Map.put_new(:effective_from, Date.utc_today())

    {:ok, version} = Catalog.publish_discount_version(scope, discount, attrs)
    version
  end

  @doc """
  Publishes a fixed amount discount version (default 50.00 DKK, priority
  100, effective today). Option `:discount` reuses an existing discount.
  """
  def fixed_discount_version_fixture(scope, attrs \\ %{}) do
    attrs = Map.new(attrs)
    {discount, attrs} = Map.pop_lazy(attrs, :discount, fn -> discount_fixture(scope) end)

    attrs =
      attrs
      |> Map.put_new(:discount_type, :fixed_amount)
      |> Map.put_new(:amount_minor, 5000)
      |> Map.put_new(:currency, "DKK")
      |> Map.put_new(:priority, 100)
      |> Map.put_new(:effective_from, Date.utc_today())

    {:ok, version} = Catalog.publish_discount_version(scope, discount, attrs)
    version
  end
end
