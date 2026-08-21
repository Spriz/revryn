defmodule BillingCore.Repo.Migrations.CreateChargeInstances do
  use Ecto.Migration

  @moduledoc """
  Idempotent one-time charge instances (SPEC §13.3 `charge_instances`,
  BC-US-041).
  """

  def change do
    create table(:charge_instances, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, references(:teams, type: :uuid), null: false
      add :external_id, :text, null: false
      add :contract_id, references(:contracts, type: :uuid), null: false
      add :subscription_id, references(:subscriptions, type: :uuid)

      # NOTE: plain uuids on purpose — billing.products / billing.price_components
      # belong to the catalog migration range; foreign keys are added once those
      # tables exist.
      add :product_id, :uuid, null: false
      add :product_version, :bigint, null: false
      add :price_component_id, :uuid

      add :status, :text, null: false
      add :eligible_on, :date, null: false
      add :quantity, :"numeric(38,18)", null: false
      add :amount_minor, :bigint
      add :currency, :"char(3)", null: false
      add :recognition_mode, :text, null: false
      add :service_start, :date
      add :service_end_exclusive, :date
      add :canonical_payload, :map, null: false
      add :payload_hash, :text, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:charge_instances, :charge_instances_status_check,
             check: "status in ('pending', 'frozen', 'cancelled', 'credited')",
             prefix: "billing"
           )

    # Over-time charges require a half-open service period; point-in-time
    # charges must not carry one (INV: recognition policy is explicit).
    create constraint(:charge_instances, :charge_instances_recognition_check,
             check: """
             (recognition_mode = 'point_in_time' and service_start is null and service_end_exclusive is null)
             or
             (recognition_mode = 'over_time' and service_start is not null and service_end_exclusive is not null and service_start < service_end_exclusive)
             """,
             prefix: "billing"
           )

    create unique_index(:charge_instances, [:team_id, :external_id], prefix: "billing")
    create index(:charge_instances, [:contract_id], prefix: "billing")
    create index(:charge_instances, [:subscription_id], prefix: "billing")
    create index(:charge_instances, [:team_id, :status, :eligible_on], prefix: "billing")
  end
end
