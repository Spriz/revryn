defmodule BillingCore.Contracts.CustomerErpMapping do
  @moduledoc """
  Mapping of a billing customer to an ERP-side customer number
  (SPEC §13.3 `customer_erp_mappings`, BC-US-031).

  Validation against the live ERP record is performed by the ERP adapter
  context; this schema only persists the mapping plus its last validation
  evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Contracts.Customer

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_erp_mappings" do
    field :team_id, Ecto.UUID
    field :erp_connection_id, Ecto.UUID
    field :external_customer_number, :string
    field :validation_status, :string
    field :external_snapshot, :map
    field :external_snapshot_hash, :string
    field :validated_at, :utc_datetime_usec

    belongs_to :customer, Customer

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :external_customer_number,
      :validation_status,
      :external_snapshot,
      :external_snapshot_hash,
      :validated_at
    ])
    |> validate_required([:external_customer_number, :validation_status])
    |> unique_constraint([:team_id, :erp_connection_id, :customer_id])
    |> unique_constraint([:team_id, :erp_connection_id, :external_customer_number])
  end
end
