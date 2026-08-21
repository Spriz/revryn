defmodule BillingCore.Catalog.DiscountTest do
  @moduledoc """
  Discount definition, assignment, and prospective deactivation rules
  (BC-US-060/061/062).
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Catalog, Outbox, Repo}
  alias BillingCore.Catalog.DiscountVersion

  import BillingCore.CatalogFixtures

  setup do
    %{scope: catalog_scope_fixture([:billing_admin])}
  end

  describe "percentage discounts (BC-US-060)" do
    test "publishes immutable versions with a content hash", %{scope: scope} do
      discount = discount_fixture(scope, %{code: "welcome"})

      version =
        percentage_discount_version_fixture(scope,
          discount: discount,
          basis_points: 2500,
          eligible_scope: %{"products" => ["seats"]},
          max_billing_periods: 6
        )

      assert version.version == 1
      assert version.discount_type == :percentage
      assert version.basis_points == 2500
      assert version.amount_minor == nil
      assert version.currency == nil
      assert is_binary(version.content_hash)
      assert Repo.get!(BillingCore.Catalog.Discount, discount.id).current_version == 1

      assert Repo.exists?(
               from e in Outbox.Event,
                 where:
                   e.event_type == "discount.version_published.v1" and
                     e.aggregate_id == ^discount.id and e.aggregate_version == 1
             )

      # A second publication appends version 2; version 1 is untouched.
      v2 = percentage_discount_version_fixture(scope, discount: discount, basis_points: 1000)
      assert v2.version == 2
      assert v2.content_hash != version.content_hash
    end

    test "basis points must stay in 1..10000 (> 0% and <= 100%)", %{scope: scope} do
      discount = discount_fixture(scope)

      for invalid <- [0, -5, 10_001] do
        assert {:error, changeset} =
                 Catalog.publish_discount_version(scope, discount, %{
                   discount_type: :percentage,
                   basis_points: invalid,
                   priority: 100,
                   effective_from: Date.utc_today()
                 })

        assert %{basis_points: [_message]} = errors_on(changeset)
      end
    end

    test "percentage versions must not carry fixed amount fields", %{scope: scope} do
      discount = discount_fixture(scope)

      assert {:error, changeset} =
               Catalog.publish_discount_version(scope, discount, %{
                 discount_type: :percentage,
                 basis_points: 500,
                 amount_minor: 100,
                 currency: "DKK",
                 priority: 100,
                 effective_from: Date.utc_today()
               })

      assert %{
               amount_minor: ["must be blank for percentage discounts"],
               currency: ["must be blank for percentage discounts"]
             } = errors_on(changeset)
    end
  end

  describe "fixed amount discounts (BC-US-061)" do
    test "requires a positive minor amount and a currency", %{scope: scope} do
      discount = discount_fixture(scope)

      assert {:error, changeset} =
               Catalog.publish_discount_version(scope, discount, %{
                 discount_type: :fixed_amount,
                 amount_minor: 0,
                 priority: 100,
                 effective_from: Date.utc_today()
               })

      errors = errors_on(changeset)
      assert %{amount_minor: [_positive]} = errors
      assert %{currency: ["can't be blank"]} = errors

      version = fixed_discount_version_fixture(scope, amount_minor: 5000, currency: "DKK")
      assert version.amount_minor == 5000
      assert version.currency == "DKK"
      assert version.basis_points == nil
      assert version.allocation_policy == "proportional"
    end

    test "fixed versions must not carry basis points", %{scope: scope} do
      discount = discount_fixture(scope)

      assert {:error, changeset} =
               Catalog.publish_discount_version(scope, discount, %{
                 discount_type: :fixed_amount,
                 amount_minor: 100,
                 currency: "DKK",
                 basis_points: 500,
                 priority: 100,
                 effective_from: Date.utc_today()
               })

      assert %{basis_points: ["must be blank for fixed amount discounts"]} = errors_on(changeset)
    end
  end

  describe "duration limits (BC-US-062)" do
    test "effective interval must be well-formed and periods positive", %{scope: scope} do
      discount = discount_fixture(scope)

      assert {:error, changeset} =
               Catalog.publish_discount_version(scope, discount, %{
                 discount_type: :percentage,
                 basis_points: 100,
                 priority: 100,
                 effective_from: ~D[2026-09-01],
                 effective_until_exclusive: ~D[2026-09-01],
                 max_billing_periods: 0
               })

      errors = errors_on(changeset)
      assert %{effective_until_exclusive: ["must be after effective_from"]} = errors
      assert %{max_billing_periods: [_positive]} = errors
    end

    test "published versions are append-only at the database", %{scope: scope} do
      version = percentage_discount_version_fixture(scope)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(from(v in DiscountVersion, where: v.id == ^version.id),
          set: [basis_points: 9999]
        )
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(v in DiscountVersion, where: v.id == ^version.id))
      end
    end
  end

  describe "assign_discount/3" do
    test "targets exactly one contract or subscription", %{scope: scope} do
      version = percentage_discount_version_fixture(scope)
      contract_id = Ecto.UUID.generate()
      subscription_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Catalog.assign_discount(scope, version, %{effective_from: Date.utc_today()})

      assert %{contract_id: ["exactly one of contract or subscription is required"]} =
               errors_on(changeset)

      assert {:error, changeset} =
               Catalog.assign_discount(scope, version, %{
                 contract_id: contract_id,
                 subscription_id: subscription_id,
                 effective_from: Date.utc_today()
               })

      assert %{contract_id: ["cannot target both a contract and a subscription"]} =
               errors_on(changeset)

      assert {:ok, assignment} =
               Catalog.assign_discount(scope, version, %{
                 subscription_id: subscription_id,
                 effective_from: Date.utc_today()
               })

      assert assignment.status == :active
      assert assignment.contract_id == nil

      assert Repo.exists?(
               from e in Outbox.Event,
                 where:
                   e.event_type == "discount.assignment_changed.v1" and
                     e.aggregate_id == ^assignment.id
             )
    end
  end

  describe "deactivate_assignment/3" do
    setup %{scope: scope} do
      version = percentage_discount_version_fixture(scope)

      {:ok, assignment} =
        Catalog.assign_discount(scope, version, %{
          contract_id: Ecto.UUID.generate(),
          effective_from: ~D[2026-01-01]
        })

      %{assignment: assignment}
    end

    test "is prospective: never in the past, never rewriting the row", %{
      scope: scope,
      assignment: assignment
    } do
      yesterday = Date.add(Date.utc_today(), -1)

      assert {:error, :retroactive_deactivation} =
               Catalog.deactivate_assignment(scope, assignment, yesterday)

      assert {:ok, deactivated} = Catalog.deactivate_assignment(scope, assignment)
      assert deactivated.status == :deactivated
      assert deactivated.effective_until_exclusive == Date.utc_today()
      # The effective start is untouched — history is preserved.
      assert deactivated.effective_from == ~D[2026-01-01]

      assert {:error, :not_active} = Catalog.deactivate_assignment(scope, deactivated)
    end

    test "cannot end before the assignment starts or extend an existing end", %{scope: scope} do
      version = percentage_discount_version_fixture(scope)
      future_start = Date.add(Date.utc_today(), 30)

      {:ok, not_started} =
        Catalog.assign_discount(scope, version, %{
          contract_id: Ecto.UUID.generate(),
          effective_from: future_start
        })

      assert {:error, :invalid_interval} =
               Catalog.deactivate_assignment(scope, not_started, Date.utc_today())

      {:ok, bounded} =
        Catalog.assign_discount(scope, version, %{
          contract_id: Ecto.UUID.generate(),
          effective_from: ~D[2026-01-01],
          effective_until_exclusive: Date.add(Date.utc_today(), 10)
        })

      assert {:error, :invalid_interval} =
               Catalog.deactivate_assignment(scope, bounded, Date.add(Date.utc_today(), 20))

      assert {:ok, shortened} =
               Catalog.deactivate_assignment(scope, bounded, Date.add(Date.utc_today(), 5))

      assert shortened.effective_until_exclusive == Date.add(Date.utc_today(), 5)
    end
  end

  describe "authorization" do
    test "mutations require billing_admin or team_admin", %{scope: scope} do
      auditor = scope_with_roles(scope, [:auditor])
      version = percentage_discount_version_fixture(scope)

      assert {:error, :unauthorized} = Catalog.create_discount(auditor, %{code: "nope"})

      assert {:error, :unauthorized} =
               Catalog.assign_discount(auditor, version, %{
                 contract_id: Ecto.UUID.generate(),
                 effective_from: Date.utc_today()
               })

      # team_admin is a valid mutation role.
      team_admin = scope_with_roles(scope, [:team_admin])
      assert {:ok, _discount} = Catalog.create_discount(team_admin, %{code: unique_code("ta")})
    end
  end
end
