defmodule BillingCore.Repo.Migrations.CreateSubscriptionChanges do
  use Ecto.Migration

  @moduledoc """
  Append-only subscription command record (SPEC §13.3 `subscription_changes`):
  start, quantity change, plan change, pause, resume, cancellation, and
  correction, with effective date, idempotency key, actor, payload, result.
  """

  def up do
    create table(:subscription_changes, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :subscription_id, references(:subscriptions, type: :uuid), null: false
      add :change_type, :text, null: false
      add :effective_date, :date, null: false
      add :idempotency_key, :text, null: false
      add :actor_reference, :text
      add :payload, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:subscription_changes, :subscription_changes_type_check,
             check:
               "change_type in ('start', 'quantity_change', 'plan_change', 'pause', 'resume', 'cancel', 'correction')",
             prefix: "billing"
           )

    create unique_index(:subscription_changes, [:team_id, :subscription_id, :idempotency_key],
             prefix: "billing"
           )

    # INV: the command record is append-only evidence.
    execute """
    CREATE TRIGGER subscription_changes_append_only
      BEFORE UPDATE OR DELETE ON billing.subscription_changes
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS subscription_changes_append_only ON billing.subscription_changes"

    drop table(:subscription_changes, prefix: "billing")
  end
end
