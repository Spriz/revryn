defmodule BillingCore.Contracts.Customer do
  @moduledoc """
  Team-owned billing customer aggregate (SPEC §13.3 `customers`, BC-US-030).

  The row carries only identity and lifecycle; every invoicing-relevant fact
  lives in the immutable `BillingCore.Contracts.CustomerVersion` snapshot the
  aggregate's `current_version` points at.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customers" do
    field :team_id, Ecto.UUID
    field :external_id, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :current_version, :integer

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(customer, attrs) do
    customer
    |> cast(attrs, [:external_id, :status])
    |> validate_required([:external_id])
    |> validate_length(:external_id, max: 200)
    |> unique_constraint([:team_id, :external_id],
      message: "external_id already used by another customer in this team"
    )
  end

  @doc false
  def update_changeset(customer, attrs) do
    cast(customer, attrs, [:status])
  end
end
