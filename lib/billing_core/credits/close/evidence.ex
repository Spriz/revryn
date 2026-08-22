defmodule BillingCore.Credits.Close.Evidence do
  @moduledoc "Append-only stored report, provider, and reconciliation evidence."

  use Ecto.Schema

  alias BillingCore.Credits.Close.Close

  @type t :: %__MODULE__{}
  @evidence_types [
    :canonical_json,
    :csv_detail,
    :pdf_summary,
    :manifest,
    :erp_voucher,
    :erp_attachment,
    :reconciliation
  ]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_close_evidence" do
    field :team_id, Ecto.UUID
    field :evidence_type, Ecto.Enum, values: @evidence_types
    field :storage_key, :string
    field :sha256, :string
    field :content_type, :string
    field :bytes, :binary
    field :metadata, :map, default: %{}

    belongs_to :close, Close

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  def evidence_types, do: @evidence_types
end
