defmodule BillingCore.Identity.WebauthnCredential do
  @moduledoc """
  Registered WebAuthn/FIDO2 passkey (SPEC §13.3, §19.2, BC-US-145).

  Stores public credential material only — private keys never exist
  server-side. Ceremony logic (challenges, attestation, assertion) lives in
  the authentication adapter, not here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "webauthn_credentials" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :backup_eligible, :boolean
    field :backup_state, :boolean
    field :transports, {:array, :string}
    field :name, :string
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :credential_id,
      :public_key,
      :sign_count,
      :backup_eligible,
      :backup_state,
      :transports,
      :name,
      :last_used_at
    ])
    |> validate_required([:credential_id, :public_key, :name])
    |> validate_number(:sign_count, greater_than_or_equal_to: 0)
    |> unique_constraint(:credential_id)
  end
end
