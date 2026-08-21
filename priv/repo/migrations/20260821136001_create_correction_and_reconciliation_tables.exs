defmodule BillingCore.Repo.Migrations.CreateCorrectionAndReconciliationTables do
  use Ecto.Migration

  @moduledoc """
  Correction cases and reconciliation results (SPEC §13.3, BC-US-104/113).
  """

  def change do
    create table(:correction_cases, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false

      add :original_invoice_intent_id,
          references(:invoice_intents, type: :uuid, prefix: "billing"),
          null: false

      add :original_booked_number, :text
      add :credit_invoice_intent_id, references(:invoice_intents, type: :uuid, prefix: "billing")

      add :replacement_invoice_intent_id,
          references(:invoice_intents, type: :uuid, prefix: "billing")

      add :reason_code, :text, null: false
      add :narrative, :text
      add :status, :text, null: false, default: "open"
      add :created_by, :text
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:correction_cases, :correction_cases_status_check,
             prefix: "billing",
             check: "status in ('open','credit_pending','completed','cancelled')"
           )

    create index(:correction_cases, [:team_id, :status], prefix: "billing")
    create index(:correction_cases, [:original_invoice_intent_id], prefix: "billing")

    create table(:reconciliation_results, primary_key: false, prefix: "billing") do
      add :id, :uuid, primary_key: true
      add :team_id, :uuid, null: false
      add :erp_document_id, references(:erp_documents, type: :uuid, prefix: "billing")
      add :run_kind, :text, null: false
      add :expected_hash, :text
      add :actual_hash, :text
      add :status, :text, null: false
      add :differences, :map, null: false, default: %{}
      add :external_snapshot, :map
      add :ran_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:reconciliation_results, :reconciliation_results_status_check,
             prefix: "billing",
             check: "status in ('match','mismatch','missing','error')"
           )

    create index(:reconciliation_results, [:team_id, :ran_at], prefix: "billing")
    create index(:reconciliation_results, [:erp_document_id, :ran_at], prefix: "billing")
  end
end
