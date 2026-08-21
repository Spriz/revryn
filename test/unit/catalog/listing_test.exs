defmodule BillingCore.Catalog.ListingTest do
  @moduledoc "Read-only catalog listing helpers for the LiveView surfaces."

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures

  alias BillingCore.Catalog

  setup do
    %{scope: catalog_scope_fixture([:billing_admin])}
  end

  test "list_plans/1 lists the team's plans by code", %{scope: scope} do
    plan_b = plan_fixture(scope, %{code: "b-plan"})
    plan_a = plan_fixture(scope, %{code: "a-plan"})
    _other = plan_fixture(catalog_scope_fixture())

    assert {:ok, plans} = Catalog.list_plans(scope)
    assert Enum.map(plans, & &1.id) == [plan_a.id, plan_b.id]
  end

  test "list_plan_versions/2 lists ascending versions", %{scope: scope} do
    plan = plan_fixture(scope)
    v1 = draft_plan_version_fixture(scope, %{plan: plan})
    v2 = draft_plan_version_fixture(scope, %{plan: plan})

    assert {:ok, versions} = Catalog.list_plan_versions(scope, plan)
    assert Enum.map(versions, & &1.id) == [v1.id, v2.id]
    assert Enum.map(versions, & &1.version) == [1, 2]
  end

  test "get_plan_version/2 fetches drafts as well as published versions", %{scope: scope} do
    draft = draft_plan_version_fixture(scope)
    published = published_plan_version_fixture(scope)

    assert {:ok, %{status: :draft}} = Catalog.get_plan_version(scope, draft.id)
    assert {:ok, %{status: :published}} = Catalog.get_plan_version(scope, published.id)

    other_scope = catalog_scope_fixture()
    assert {:error, :not_found} = Catalog.get_plan_version(other_scope, draft.id)
  end

  test "list_price_components/2 orders by ordinal", %{scope: scope} do
    draft = draft_plan_version_fixture(scope)
    first = fixed_recurring_component_fixture(scope, draft, ordinal: 0)
    second = fixed_recurring_component_fixture(scope, draft, ordinal: 1)

    assert {:ok, components} = Catalog.list_price_components(scope, draft)
    assert Enum.map(components, & &1.id) == [first.id, second.id]
  end
end
