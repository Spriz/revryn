defmodule BillingCore.Contracts.ContractVersion do
  @moduledoc """
  Immutable contract version snapshot (SPEC §13.3 `contract_versions`,
  BC-US-033): customer version, currency, effective dates, and approved
  metadata, hashed via `BillingCore.Domain.Canonical`.
  """

  use Ecto.Schema

  alias BillingCore.Contracts.Contract

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "contract_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :customer_version, :integer
    field :currency, :string
    field :effective_start, :date
    field :effective_end_exclusive, :date
    field :metadata, :map, default: %{}
    field :content_hash, :string

    belongs_to :contract, Contract

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end
end
