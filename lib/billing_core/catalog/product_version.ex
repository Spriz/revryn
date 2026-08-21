defmodule BillingCore.Catalog.ProductVersion do
  @moduledoc """
  Immutable product snapshot with the accountant-approved recognition policy
  (SPEC §13.3 `product_versions`, BC-US-011). The table is append-only at
  the database; `content_hash` is the canonical SHA-256 of `snapshot`
  (`BillingCore.Domain.Canonical`).
  """

  use Ecto.Schema

  alias BillingCore.Catalog.Product

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "product_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :name, :string
    field :description, :string
    field :recognition_mode, Ecto.Enum, values: [:point_in_time, :over_time]

    field :service_period_source, Ecto.Enum,
      values: [:billing_period, :subscription_period, :explicit]

    field :approver_reference, :string
    field :approved_at, :utc_datetime_usec
    field :evidence_reference, :string
    field :snapshot, :map
    field :content_hash, :string

    belongs_to :product, Product

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end
end
