defmodule BillingCore.Identity.FederatedIdentity do
  @moduledoc """
  OIDC issuer/subject mapping to a global user (SPEC §13.3, §19.2).

  Federation maps external identities onto the same global user/membership
  model — it never bypasses it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "federated_identities" do
    field :issuer, :string
    field :subject, :string

    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:issuer, :subject])
    |> validate_required([:issuer, :subject])
    |> unique_constraint([:issuer, :subject])
  end
end
