defmodule BillingCore.Workflows.CatalogPublicationTest do
  @moduledoc """
  Catalog publication journey (SPEC Epic B): product → plan → draft version
  → price components → publish → database-enforced immutability → next
  version → retire. Reads as documentation of BC-US-010/013/014/015.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Catalog, Outbox, Repo}
  alias BillingCore.Catalog.{Plan, PlanVersion}
  alias BillingCore.Pricing.Model.FixedRecurring

  import BillingCore.CatalogFixtures

  setup do
    %{scope: catalog_scope_fixture([:billing_admin])}
  end

  test "full journey: draft, publish, immutability, v2, pinning, retire", %{scope: scope} do
    # A product administrator creates a stable commercial product…
    {:ok, product} =
      Catalog.create_product(scope, %{code: "seats", name: "Seats"})

    assert product.status == :active
    assert product.current_version == 1

    # …and assembles a plan from versioned price components (BC-US-013).
    {:ok, plan} = Catalog.create_plan(scope, %{code: "team-monthly", name: "Team Monthly"})
    assert plan.current_version == 0

    {:ok, draft} =
      Catalog.create_draft_plan_version(scope, plan, %{
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        billing_timing: :in_advance
      })

    assert draft.version == 1
    assert draft.status == :draft

    # A valid fixed recurring component is accepted; its definition is
    # stored in canonical form (BC-US-015).
    {:ok, component} =
      Catalog.add_price_component(scope, draft, %{
        code: "base-fee",
        product_id: product.id,
        pricing_definition: fixed_recurring_definition("99.50")
      })

    assert component.pricing_model == "fixed_recurring"
    assert component.pricing_definition["unit_price"] == "99.5"
    assert component.product_version == 1
    assert component.recognition_mode == :point_in_time

    # An invalid tier definition is rejected immediately with the pricing
    # model's own reasons (BC-US-018: tiers must be contiguous).
    gapped_tiers = %{
      "schema_version" => 1,
      "type" => "volume_tier",
      "tiers" => [
        %{"from" => "0", "to" => "10", "unit_rate" => "1"},
        %{"from" => "20", "unit_rate" => "0.5"}
      ]
    }

    assert {:error, {:invalid_pricing_definition, reasons}} =
             Catalog.add_price_component(scope, draft, %{
               code: "usage",
               product_id: product.id,
               metric_code: "api_calls",
               aggregation: :sum,
               pricing_definition: gapped_tiers
             })

    assert reasons == [not_contiguous: 1]

    # Publication freezes the version (BC-US-014).
    assert {:ok, published} = Catalog.publish_plan_version(scope, draft)
    assert published.status == :published
    assert published.published_by == scope.user.id
    assert is_binary(published.content_hash)
    assert [%{"code" => "base-fee"}] = published.definition["components"]

    assert Repo.get!(Plan, plan.id).current_version == 1

    assert Repo.exists?(
             from e in Outbox.Event,
               where:
                 e.event_type == "plan.version_published.v1" and e.aggregate_id == ^plan.id and
                   e.aggregate_version == 1
           )

    # The context refuses mutation of the published version…
    assert {:error, :published_immutable} =
             Catalog.update_draft_plan_version(scope, published, %{currency: "EUR"})

    assert {:error, :published_immutable} =
             Catalog.add_price_component(scope, published, %{
               code: "late",
               product_id: product.id,
               pricing_definition: fixed_recurring_definition()
             })

    assert {:error, :published_immutable} = Catalog.update_price_component(scope, component, %{})
    assert {:error, :published_immutable} = Catalog.remove_price_component(scope, component)
    assert {:error, :published_immutable} = Catalog.delete_draft_plan_version(scope, published)

    # …and the database rejects UPDATE even when the context is bypassed.
    assert_raise Postgrex.Error, ~r/published versions are immutable/, fn ->
      Repo.update_all(from(v in PlanVersion, where: v.id == ^published.id),
        set: [currency: "EUR"]
      )
    end

    assert_raise Postgrex.Error, ~r/only drafts may be deleted/, fn ->
      Repo.delete_all(from(v in PlanVersion, where: v.id == ^published.id))
    end

    # Later changes create a new version with its own content.
    {:ok, draft_v2} =
      Catalog.create_draft_plan_version(scope, plan, %{
        currency: "DKK",
        interval_unit: :month,
        interval_count: 1,
        billing_timing: :in_advance,
        effective_from: ~D[2027-01-01]
      })

    assert draft_v2.version == 2

    fixed_recurring_component_fixture(scope, draft_v2,
      product: product,
      code: "base-fee",
      amount: "120"
    )

    assert {:ok, published_v2} = Catalog.publish_plan_version(scope, draft_v2)
    assert published_v2.content_hash != published.content_hash

    # Existing subscriptions stay pinned to their assigned version: v1 is
    # untouched — only plans.current_version moved (BC-US-014).
    assert Repo.get!(Plan, plan.id).current_version == 2
    v1_after = Repo.get!(PlanVersion, published.id)
    assert v1_after.status == :published
    assert v1_after.content_hash == published.content_hash
    assert v1_after.definition == published.definition

    # Published versions load with components and always re-parse into
    # pricing model structs.
    assert {:ok, loaded} = Catalog.get_published_plan_version(scope, published_v2.id)
    assert [loaded_component] = loaded.price_components

    assert {:ok, [{^loaded_component, %FixedRecurring{} = model}]} =
             Catalog.fetch_pricing_models(loaded)

    assert Decimal.eq?(model.unit_price, Decimal.new("120"))

    # Retirement is the single permitted post-publication transition.
    assert {:ok, retired} = Catalog.retire_plan_version(scope, published)
    assert retired.status == :retired
    assert {:error, :not_found} = Catalog.get_published_plan_version(scope, published.id)

    assert_raise Postgrex.Error, ~r/published versions are immutable/, fn ->
      Repo.update_all(from(v in PlanVersion, where: v.id == ^retired.id),
        set: [status: "published"]
      )
    end
  end

  test "publication fails without components", %{scope: scope} do
    draft = draft_plan_version_fixture(scope)
    assert {:error, :no_components} = Catalog.publish_plan_version(scope, draft)
  end

  test "publication fails when a component's product is inactive", %{scope: scope} do
    product = product_fixture(scope)
    draft = draft_plan_version_fixture(scope)
    fixed_recurring_component_fixture(scope, draft, product: product, code: "base")

    {:ok, _inactive} = Catalog.deactivate_product(scope, product)

    assert {:error, {:product_inactive, "base"}} = Catalog.publish_plan_version(scope, draft)
  end

  test "over_time components without a service period source never reach publication",
       %{scope: scope} do
    # The rule is enforced the moment the component enters the catalog
    # (schema validation + database CHECK), so an invalid component cannot
    # exist for publish to find (SPEC §9.4, BC-US-011).
    product = product_fixture(scope)
    draft = draft_plan_version_fixture(scope)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Catalog.add_price_component(scope, draft, %{
               code: "accrued",
               product_id: product.id,
               recognition_mode: :over_time,
               pricing_definition: fixed_recurring_definition()
             })

    assert %{service_period_source: ["is required for over_time recognition"]} =
             errors_on(changeset)

    # With a source it publishes — the component inherits nothing silently.
    {:ok, _component} =
      Catalog.add_price_component(scope, draft, %{
        code: "accrued",
        product_id: product.id,
        recognition_mode: :over_time,
        service_period_source: :billing_period,
        pricing_definition: fixed_recurring_definition()
      })

    assert {:ok, published} = Catalog.publish_plan_version(scope, draft)

    assert [%{"recognition_mode" => "over_time", "service_period_source" => "billing_period"}] =
             published.definition["components"]
  end

  test "components inherit the product's recognition policy by default", %{scope: scope} do
    product =
      product_fixture(scope, %{
        recognition_mode: :over_time,
        service_period_source: :billing_period,
        approver_reference: "auditor-42"
      })

    draft = draft_plan_version_fixture(scope)
    component = fixed_recurring_component_fixture(scope, draft, product: product)

    assert component.recognition_mode == :over_time
    assert component.service_period_source == :billing_period
  end

  test "draft plan versions may be edited and deleted before publication", %{scope: scope} do
    draft = draft_plan_version_fixture(scope, %{currency: "DKK"})
    fixed_recurring_component_fixture(scope, draft)

    assert {:ok, updated} = Catalog.update_draft_plan_version(scope, draft, %{currency: "EUR"})
    assert updated.currency == "EUR"

    assert {:ok, _deleted} = Catalog.delete_draft_plan_version(scope, updated)
    assert Repo.get(PlanVersion, draft.id) == nil
  end

  test "whole-month intervals only allow 1/2/3/4/6/12 (SPEC §9.5)", %{scope: scope} do
    plan = plan_fixture(scope)

    assert {:error, changeset} =
             Catalog.create_draft_plan_version(scope, plan, %{
               currency: "DKK",
               interval_unit: :month,
               interval_count: 5,
               billing_timing: :in_advance
             })

    assert %{interval_count: [_message]} = errors_on(changeset)

    assert {:ok, _quarterly} =
             Catalog.create_draft_plan_version(scope, plan, %{
               currency: "DKK",
               interval_unit: :month,
               interval_count: 3,
               billing_timing: :in_arrears
             })
  end

  test "mutations require billing_admin or team_admin", %{scope: scope} do
    auditor = scope_with_roles(scope, [:auditor])
    published = published_plan_version_fixture(scope)

    assert {:error, :unauthorized} = Catalog.create_plan(auditor, %{code: "x", name: "X"})
    assert {:error, :unauthorized} = Catalog.retire_plan_version(auditor, published)

    # Reads are open to every team role.
    assert {:ok, _loaded} = Catalog.get_published_plan_version(auditor, published.id)
  end
end
