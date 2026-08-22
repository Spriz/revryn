defmodule BillingCore.ERP.Connection do
  @moduledoc "ERP connection (SPEC §13.3 `erp_connections`, BC-US-003)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  schema "erp_connections" do
    field :team_id, Ecto.UUID
    field :provider, :string
    field :external_agreement_id, :string
    field :secret_reference, :string
    field :status, :string, default: "unvalidated"
    field :capabilities, :map, default: %{}
    field :capabilities_hash, :string
    field :preflight_result, :map
    field :last_validated_at, :utc_datetime_usec
    field :webhook_token_hash, :string
    field :version, :integer, default: 1
    timestamps()
  end
end

defmodule BillingCore.ERP.ErpDocument do
  @moduledoc "External ERP document mirror (SPEC §13.3 `erp_documents`)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  schema "erp_documents" do
    field :team_id, Ecto.UUID
    field :erp_connection_id, Ecto.UUID
    field :invoice_intent_id, Ecto.UUID
    field :customer_credit_close_id, Ecto.UUID
    field :document_type, :string, default: "invoice"
    field :state, :string, default: "pending"
    field :external_draft_number, :string
    field :external_booked_number, :string
    field :external_voucher_number, :string
    field :external_accounting_year, :string
    field :external_reference, :string
    field :last_external_snapshot, :map
    field :last_external_hash, :string
    field :last_reconciled_at, :utc_datetime_usec
    field :version, :integer, default: 1
    timestamps()
  end
end

defmodule BillingCore.ERP.SyncOperation do
  @moduledoc "ERP write/read evidence linked to a durable operation (SPEC §13.3)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "sync_operations" do
    field :team_id, Ecto.UUID
    field :erp_document_id, Ecto.UUID
    field :operation_id, Ecto.UUID
    field :operation_type, :string
    field :operation_key, :string
    field :idempotency_key, :string
    field :request_hash, :string
    field :request_metadata, :map, default: %{}
    field :response_metadata, :map
    field :state, :string, default: "queued"
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :last_error, :map
    field :created_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
  end
end

defmodule BillingCore.ERP.WebhookReceipt do
  @moduledoc "Durable, redacted webhook receipt (SPEC §13.3, §17.11)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "webhook_receipts" do
    field :provider, :string
    field :team_id, Ecto.UUID
    field :erp_connection_id, Ecto.UUID
    field :provider_event_id, :string
    field :received_at, :utc_datetime_usec
    field :headers_redacted, :map, default: %{}
    field :payload_redacted, :map, default: %{}
    field :payload_hash, :string
    field :processing_state, :string, default: "received"
  end
end

defmodule BillingCore.ERP.ApprovalRecord do
  @moduledoc "Append-only approval evidence (SPEC §13.3, BC-US-084)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "approval_records" do
    field :team_id, Ecto.UUID
    field :invoice_intent_id, Ecto.UUID
    field :action, :string
    field :actor_type, :string
    field :actor_id, :string
    field :reason, :string
    field :intent_hash, :string
    field :erp_draft_hash, :string
    field :occurred_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end
end
