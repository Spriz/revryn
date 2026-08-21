defmodule BillingCore.Identity.Session do
  @moduledoc """
  Revocable server-side session (SPEC §13.3, §19.2).

  Only the SHA-256 hash of the opaque session token is stored. The session
  carries authentication strength and time so sensitive operations can
  require recent step-up.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "sessions" do
    field :token_hash, :string, redact: true
    field :authenticated_at, :utc_datetime_usec
    field :strength, Ecto.Enum, values: [:passkey, :passkey_plus_totp, :recovery]
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :ip, :string
    field :user_agent, :string

    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:authenticated_at, :strength, :expires_at, :ip, :user_agent])
    |> validate_required([:authenticated_at, :strength, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
