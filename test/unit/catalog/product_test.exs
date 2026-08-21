defmodule BillingCore.Catalog.ProductTest do
  @moduledoc """
  Product versioning, recognition policy, code immutability, and ERP
  mapping rules (BC-US-010/011/012).
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Catalog, Outbox, Repo}
  alias BillingCore.Catalog.{Product, ProductVersion}

  import BillingCore.CatalogFixtures

  setup do
    %{scope: catalog_scope_fixture([:billing_admin])}
  end

  describe "create_product/2" do
    test "creates the head plus immutable version 1 with a content hash", %{scope: scope} do
      {:ok, product} =
        Catalog.create_product(scope, %{
          code: "support",
          name: "Support",
          recognition_mode: :over_time,
          service_period_source: :subscription_period,
          approver_reference: "auditor-1",
          approved_at: ~U[2026-08-01 12:00:00.000000Z]
        })

      assert product.current_version == 1

      assert {:ok, [version]} = Catalog.list_product_versions(scope, product)
      assert version.version == 1
      assert version.recognition_mode == :over_time
      assert version.service_period_source == :subscription_period
      assert version.snapshot["code"] == "support"
      assert is_binary(version.content_hash)

      assert Repo.exists?(
               from e in Outbox.Event,
                 where:
                   e.event_type == "product.version_created.v1" and
                     e.aggregate_id == ^product.id and e.aggregate_version == 1
             )
    end

    test "over_time requires a service period source (BC-US-011)", %{scope: scope} do
      assert {:error, changeset} =
               Catalog.create_product(scope, %{
                 code: "accrued",
                 name: "Accrued",
                 recognition_mode: :over_time
               })

      assert %{service_period_source: ["is required for over_time recognition"]} =
               errors_on(changeset)
    end

    test "code is unique per team but free across teams", %{scope: scope} do
      product_fixture(scope, %{code: "dup"})

      assert {:error, changeset} = Catalog.create_product(scope, %{code: "dup", name: "Again"})
      assert %{code: [_taken]} = errors_on(changeset)

      other_team_scope = catalog_scope_fixture([:billing_admin])
      assert {:ok, _product} = Catalog.create_product(other_team_scope, %{code: "dup", name: "X"})
    end
  end

  describe "update_product/3" do
    test "appends a new immutable version and bumps the head", %{scope: scope} do
      product = product_fixture(scope, %{name: "Before"})

      {:ok, updated} =
        Catalog.update_product(scope, product, %{
          name: "After",
          recognition_mode: :over_time,
          service_period_source: :billing_period,
          approver_reference: "auditor-2"
        })

      assert updated.current_version == 2
      assert {:ok, [v1, v2]} = Catalog.list_product_versions(scope, product)
      assert v1.name == "Before"
      assert v2.name == "After"
      assert v2.recognition_mode == :over_time
      assert v1.content_hash != v2.content_hash
    end

    test "code changes are rejected once a price component references the product",
         %{scope: scope} do
      product = product_fixture(scope, %{code: "referenced"})
      draft = draft_plan_version_fixture(scope)
      fixed_recurring_component_fixture(scope, draft, product: product)

      assert {:error, :code_immutable} =
               Catalog.update_product(scope, product, %{code: "renamed", name: "New"})

      # Non-code updates still version normally.
      assert {:ok, updated} =
               Catalog.update_product(scope, product, %{code: "referenced", name: "New"})

      assert updated.current_version == 2
    end
  end

  describe "immutability at the database" do
    test "product versions reject UPDATE", %{scope: scope} do
      product = product_fixture(scope)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(v in ProductVersion, where: v.product_id == ^product.id),
          set: [name: "rewritten"]
        )
      end
    end

    test "product versions reject DELETE", %{scope: scope} do
      product = product_fixture(scope)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(v in ProductVersion, where: v.product_id == ^product.id))
      end
    end

    test "the recognition CHECK rejects over_time without a source even on direct insert",
         %{scope: scope} do
      product = product_fixture(scope)

      assert_raise Ecto.ConstraintError, ~r/over_time_requires_period_source/, fn ->
        Repo.insert!(%ProductVersion{
          team_id: product.team_id,
          product_id: product.id,
          version: 99,
          name: "bad",
          recognition_mode: :over_time,
          service_period_source: nil,
          snapshot: %{},
          content_hash: "x"
        })
      end
    end
  end

  describe "deactivate_product/2" do
    test "is idempotent and keeps history", %{scope: scope} do
      product = product_fixture(scope)

      assert {:ok, inactive} = Catalog.deactivate_product(scope, product)
      assert inactive.status == :inactive
      assert {:ok, ^inactive} = Catalog.deactivate_product(scope, inactive)

      assert {:ok, [_v1]} = Catalog.list_product_versions(scope, product)
    end
  end

  describe "product ERP mappings (BC-US-012)" do
    setup %{scope: scope} do
      %{finance: scope_with_roles(scope, [:finance_operator]), product: product_fixture(scope)}
    end

    test "writes require finance_operator", %{scope: scope, finance: finance, product: product} do
      attrs = %{erp_connection_id: Ecto.UUID.generate(), external_product_number: "1010"}

      # billing_admin may mutate the catalog but not ERP mappings.
      assert {:error, :unauthorized} = Catalog.upsert_product_erp_mapping(scope, product, attrs)
      assert {:ok, mapping} = Catalog.upsert_product_erp_mapping(finance, product, attrs)
      assert mapping.validation_status == :pending
      assert mapping.validated_at == nil
    end

    test "upsert replaces the mapping and resets it to pending", %{
      finance: finance,
      product: product
    } do
      connection_id = Ecto.UUID.generate()

      {:ok, first} =
        Catalog.upsert_product_erp_mapping(finance, product, %{
          erp_connection_id: connection_id,
          external_product_number: "1010"
        })

      # Simulate the ERP context having validated the mapping.
      first
      |> Ecto.Changeset.change(
        validation_status: :valid,
        validated_at: DateTime.utc_now(),
        external_snapshot_hash: "abc"
      )
      |> Repo.update!()

      {:ok, second} =
        Catalog.upsert_product_erp_mapping(finance, product, %{
          erp_connection_id: connection_id,
          external_product_number: "2020"
        })

      assert second.id == first.id
      assert second.external_product_number == "2020"
      assert second.validation_status == :pending
      assert second.validated_at == nil
      assert second.external_snapshot_hash == nil
    end

    test "one external number maps to at most one product per connection", %{
      scope: scope,
      finance: finance,
      product: product
    } do
      connection_id = Ecto.UUID.generate()

      {:ok, _mapping} =
        Catalog.upsert_product_erp_mapping(finance, product, %{
          erp_connection_id: connection_id,
          external_product_number: "1010"
        })

      other_product = product_fixture(scope)

      assert {:error, changeset} =
               Catalog.upsert_product_erp_mapping(finance, other_product, %{
                 erp_connection_id: connection_id,
                 external_product_number: "1010"
               })

      assert %{external_product_number: [_taken]} = errors_on(changeset)
    end

    test "list and get are team-scoped reads", %{scope: scope, finance: finance, product: product} do
      {:ok, mapping} =
        Catalog.upsert_product_erp_mapping(finance, product, %{
          erp_connection_id: Ecto.UUID.generate(),
          external_product_number: "1010"
        })

      assert {:ok, [listed]} = Catalog.list_product_erp_mappings(scope, product)
      assert listed.id == mapping.id
      assert {:ok, fetched} = Catalog.get_product_erp_mapping(scope, mapping.id)
      assert fetched.id == mapping.id

      other_team = catalog_scope_fixture([:billing_admin])
      assert {:error, :not_found} = Catalog.get_product_erp_mapping(other_team, mapping.id)
    end
  end

  describe "team isolation" do
    test "possession of a product struct never grants cross-team access", %{scope: scope} do
      product = product_fixture(scope)
      other_team = catalog_scope_fixture([:billing_admin])

      assert {:error, :unauthorized} =
               Catalog.update_product(other_team, product, %{name: "stolen"})

      assert {:error, :not_found} = Catalog.fetch_product(other_team, product.id)
      assert {:ok, %Product{}} = Catalog.fetch_product(scope, product.id)
    end
  end
end
