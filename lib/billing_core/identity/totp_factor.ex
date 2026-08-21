defmodule BillingCore.Identity.TotpFactor do
  @moduledoc """
  TOTP second factor (SPEC §13.3, §19.2, BC-US-146).

  The secret is stored only as an encrypted envelope (`secret_ciphertext`)
  and is never logged or exported. Code verification/activation ceremonies
  live in the authentication adapter, not here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "totp_factors" do
    field :secret_ciphertext, :binary, redact: true
    field :activated_at, :utc_datetime_usec
    field :last_timestep, :integer
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(factor, attrs) do
    factor
    |> cast(attrs, [:secret_ciphertext, :activated_at, :last_timestep])
    |> validate_required([:secret_ciphertext])
  end
end
