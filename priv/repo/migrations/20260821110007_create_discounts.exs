defmodule BillingCore.Repo.Migrations.CreateDiscounts do
  use Ecto.Migration

  @moduledoc """
  Discounts own a stable team-scoped code; `discount_versions` is the
  immutable definition history (SPEC §13.3, BC-US-060/061/062).
  """

  def up do
    create table(:discounts, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :code, :text, null: false
      add :status, :text, null: false, default: "active"
      add :current_version, :bigint, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:discounts, :discounts_status_check,
             check: "status in ('active', 'archived')",
             prefix: "billing"
           )

    create unique_index(:discounts, [:team_id, :code], prefix: "billing")

    create table(:discount_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :discount_id, references(:discounts, type: :uuid), null: false
      add :version, :bigint, null: false
      add :discount_type, :text, null: false
      add :basis_points, :integer
      add :amount_minor, :bigint
      add :currency, :"char(3)"
      add :eligible_scope, :map, null: false, default: %{}
      add :priority, :integer, null: false
      add :effective_from, :date, null: false
      add :effective_until_exclusive, :date
      add :max_billing_periods, :integer
      add :allocation_policy, :text, null: false, default: "proportional"
      add :content_hash, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:discount_versions, :discount_versions_discount_type_check,
             check: "discount_type in ('percentage', 'fixed_amount')",
             prefix: "billing"
           )

    # INV: a percentage is > 0 and <= 100 (BC-US-060).
    create constraint(:discount_versions, :discount_versions_basis_points_check,
             check: "basis_points is null or (basis_points >= 1 and basis_points <= 10000)",
             prefix: "billing"
           )

    create constraint(:discount_versions, :discount_versions_amount_minor_check,
             check: "amount_minor is null or amount_minor > 0",
             prefix: "billing"
           )

    create constraint(:discount_versions, :discount_versions_max_billing_periods_check,
             check: "max_billing_periods is null or max_billing_periods > 0",
             prefix: "billing"
           )

    # INV: exactly one of the percentage/fixed field groups is populated.
    create constraint(:discount_versions, :discount_versions_exactly_one_type_check,
             check:
               "(discount_type = 'percentage' and basis_points is not null " <>
                 "and amount_minor is null and currency is null) or " <>
                 "(discount_type = 'fixed_amount' and amount_minor is not null " <>
                 "and currency is not null and basis_points is null)",
             prefix: "billing"
           )

    create constraint(:discount_versions, :discount_versions_effective_interval_check,
             check:
               "effective_until_exclusive is null or effective_from < effective_until_exclusive",
             prefix: "billing"
           )

    create unique_index(:discount_versions, [:team_id, :discount_id, :version], prefix: "billing")

    # INV: expiration is evaluated from immutable application data
    # (BC-US-062) — discount definitions never change in place.
    execute """
    CREATE TRIGGER discount_versions_append_only
      BEFORE UPDATE OR DELETE ON billing.discount_versions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS discount_versions_append_only ON billing.discount_versions"
    drop table(:discount_versions, prefix: "billing")
    drop table(:discounts, prefix: "billing")
  end
end
