defmodule BillingCore.Identity.RecoveryCode do
  @moduledoc """
  One-time recovery code (SPEC §13.3, §19.2, BC-US-146).

  Only a one-way hash is stored; codes are single-use (`consumed_at`) and
  issued in generation batches so a new batch invalidates the previous one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "recovery_codes" do
    field :code_hash, :string, redact: true
    field :batch, :integer
    field :consumed_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(code, attrs) do
    code
    |> cast(attrs, [:code_hash, :batch])
    |> validate_required([:code_hash, :batch])
    |> validate_number(:batch, greater_than_or_equal_to: 1)
  end
end
