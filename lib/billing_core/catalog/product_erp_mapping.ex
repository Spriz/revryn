defmodule BillingCore.Catalog.ProductErpMapping do
  @moduledoc """
  Mapping of a product to an ERP product number (SPEC §13.3
  `product_erp_mappings`, BC-US-012).

  The catalog persists mappings with `validation_status: :pending`; the ERP
  context performs provider validation and stores the external snapshot,
  checksum, and `validated_at` (and emits `product.erp_mapping_validated.v1`).
  `erp_connection_id` is a plain uuid — the `erp_connections` table is owned
  by a later migration range.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.Product

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "product_erp_mappings" do
    field :team_id, Ecto.UUID
    field :erp_connection_id, Ecto.UUID
    field :external_product_number, :string
    field :validation_status, Ecto.Enum, values: [:pending, :valid, :invalid], default: :pending
    field :external_snapshot, :map
    field :external_snapshot_hash, :string
    field :validated_at, :utc_datetime_usec

    belongs_to :product, Product

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [:erp_connection_id, :external_product_number])
    |> validate_required([:erp_connection_id, :external_product_number])
    |> validate_length(:external_product_number, max: 200)
    |> unique_constraint([:team_id, :erp_connection_id, :product_id],
      name: :product_erp_mappings_connection_product_idx,
      error_key: :erp_connection_id
    )
    |> unique_constraint([:team_id, :erp_connection_id, :external_product_number],
      name: :product_erp_mappings_connection_external_number_idx,
      error_key: :external_product_number,
      message: "external product number already mapped to another product"
    )
  end
end
