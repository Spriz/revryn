defmodule BillingCore.Billing.BillingRun do
  @moduledoc "Billing run (SPEC §13.3, §18.1)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  schema "billing_runs" do
    field :team_id, Ecto.UUID
    field :run_key, :string
    field :invoice_date, :date
    field :usage_cutoff, :utc_datetime_usec
    field :settings_version, :integer
    field :engine_version, :string
    field :status, :string, default: "open"
    field :started_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    timestamps()
  end
end

defmodule BillingCore.Billing.Charge do
  @moduledoc "Immutable rated charge before invoice consolidation (SPEC §13.3)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  schema "charges" do
    field :team_id, Ecto.UUID
    field :billing_run_id, Ecto.UUID
    field :subscription_id, Ecto.UUID
    field :charge_instance_id, Ecto.UUID
    field :price_component_id, Ecto.UUID
    field :component_code, :string
    field :product_id, Ecto.UUID
    field :product_version, :integer
    field :charge_kind, :string
    field :occurrence_key, :string
    field :status, :string, default: "active"
    field :currency, :string
    field :amount_minor, :integer
    field :unrounded, :string
    field :quantity, :decimal
    field :recognition_mode, :string
    field :service_start, :date
    field :service_end_exclusive, :date
    field :calculation_trace, :map
    field :source_hashes, :map, default: %{}
    timestamps()
  end
end

defmodule BillingCore.Billing.InvoiceChain do
  @moduledoc "Stable logical invoice identity (SPEC §13.3)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  schema "invoice_chains" do
    field :team_id, Ecto.UUID
    field :current_intent_id, Ecto.UUID
    field :status, :string, default: "active"
    field :version, :integer, default: 1
    timestamps()
  end
end

defmodule BillingCore.Billing.InvoiceIntent do
  @moduledoc "Immutable frozen invoice intent (SPEC §13.3, INV-013)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "invoice_intents" do
    field :team_id, Ecto.UUID
    field :invoice_chain_id, Ecto.UUID
    field :billing_run_id, Ecto.UUID
    field :customer_id, Ecto.UUID
    field :customer_version, :integer
    field :contract_id, Ecto.UUID
    field :currency, :string
    field :invoice_date, :date
    field :intent_version, :integer
    field :supersedes_invoice_intent_id, Ecto.UUID
    field :document_kind, :string, default: "invoice"
    field :canonical_snapshot, :map
    field :content_hash, :string
    field :net_amount_minor, :integer
    field :created_at, :utc_datetime_usec
    field :frozen_at, :utc_datetime_usec

    has_many :lines, BillingCore.Billing.InvoiceLine, foreign_key: :invoice_intent_id
  end
end

defmodule BillingCore.Billing.InvoiceLine do
  @moduledoc "Immutable normalized invoice line (SPEC §13.3, INV-003/004)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "invoice_lines" do
    field :team_id, Ecto.UUID
    field :invoice_intent_id, Ecto.UUID
    field :line_key, :string
    field :source_charge_id, Ecto.UUID
    field :adjusts_line_id, Ecto.UUID
    field :product_id, Ecto.UUID
    field :product_version, :integer
    field :description, :string
    field :quantity, :decimal
    field :display_unit, :string
    field :amount_minor, :integer
    field :currency, :string
    field :recognition_mode, :string
    field :service_start, :date
    field :service_end_exclusive, :date
    field :calculation_trace, :map
    field :ordinal, :integer
    field :created_at, :utc_datetime_usec
  end
end

defmodule BillingCore.Billing.IntentLifecycle do
  @moduledoc "Mutable lifecycle projection for an invoice intent (SPEC §13.3)."
  use Ecto.Schema

  @schema_prefix "billing"
  @primary_key {:invoice_intent_id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]
  schema "invoice_intent_lifecycle" do
    field :team_id, Ecto.UUID
    field :current_state, :string, default: "frozen"
    field :version, :integer, default: 1
    field :latest_operation_id, Ecto.UUID
    timestamps()
  end
end
