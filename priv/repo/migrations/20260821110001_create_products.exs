defmodule BillingCore.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  @moduledoc """
  Stable commercial products with a default recognition policy
  (SPEC §13.3 `products`, BC-US-010/011).
  """

  def change do
    create table(:products, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :code, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :status, :text, null: false, default: "active"
      add :recognition_mode, :text, null: false, default: "point_in_time"
      add :service_period_source, :text
      add :approver_reference, :text
      add :approved_at, :utc_datetime_usec
      add :evidence_reference, :text
      add :current_version, :bigint, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:products, :products_status_check,
             check: "status in ('active', 'inactive')",
             prefix: "billing"
           )

    create constraint(:products, :products_recognition_mode_check,
             check: "recognition_mode in ('point_in_time', 'over_time')",
             prefix: "billing"
           )

    create constraint(:products, :products_service_period_source_check,
             check:
               "service_period_source is null or " <>
                 "service_period_source in ('billing_period', 'subscription_period', 'explicit')",
             prefix: "billing"
           )

    # INV: over_time recognition always names its service-period derivation
    # rule (BC-US-011, SPEC §9.4).
    create constraint(:products, :products_over_time_requires_period_source,
             check: "recognition_mode <> 'over_time' or service_period_source is not null",
             prefix: "billing"
           )

    create unique_index(:products, [:team_id, :code], prefix: "billing")
  end
end
