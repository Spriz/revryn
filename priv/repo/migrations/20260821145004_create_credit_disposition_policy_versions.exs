defmodule BillingCore.Repo.Migrations.CreateCreditDispositionPolicyVersions do
  use Ecto.Migration

  @moduledoc """
  Immutable credit disposition policy versions (SPEC §13.3, BC-US-109,
  INV-053): what happens to unused customer credit when the commercial
  relationship terminates — `retain`, `refund`, or `expire_after` (which
  requires an explicit duration).

  v1 simplification (documented deviation from the fully general
  account/contract scoping in SPEC §13.3): policies are account-scoped only,
  so `account_id` is NOT NULL and uniqueness is the plain
  `(team_id, account_id, version)` index instead of a pair of partial
  indexes over a nullable scope. `contract_id` is retained as an optional
  informational reference for the future contract-scoped extension.
  """

  def up do
    create table(:credit_disposition_policy_versions, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :account_id, references(:accounts, type: :uuid, prefix: "billing"), null: false
      add :contract_id, :uuid
      add :version, :bigint, null: false
      add :policy, :text, null: false
      add :expire_after_days, :integer
      add :effective_from, :utc_datetime_usec, null: false
      add :created_by, :uuid
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(
             :credit_disposition_policy_versions,
             :credit_disposition_policy_versions_policy_check,
             check: "policy in ('retain','refund','expire_after')",
             prefix: "billing"
           )

    # `expire_after` requires an explicit duration (BC-US-109).
    create constraint(
             :credit_disposition_policy_versions,
             :credit_disposition_policy_versions_expire_after_check,
             check:
               "policy <> 'expire_after' or " <>
                 "(expire_after_days is not null and expire_after_days > 0)",
             prefix: "billing"
           )

    create unique_index(:credit_disposition_policy_versions, [:team_id, :account_id, :version],
             prefix: "billing"
           )

    # Policy versions are immutable — reuses billing.reject_mutation().
    execute """
    CREATE TRIGGER credit_disposition_policy_versions_append_only
      BEFORE UPDATE OR DELETE ON billing.credit_disposition_policy_versions
      FOR EACH ROW EXECUTE FUNCTION billing.reject_mutation();
    """
  end

  def down do
    execute """
    DROP TRIGGER IF EXISTS credit_disposition_policy_versions_append_only
      ON billing.credit_disposition_policy_versions
    """

    drop table(:credit_disposition_policy_versions, prefix: "billing")
  end
end
