defmodule BillingCore.Identity.UserEmail do
  @moduledoc """
  Email address belonging to a global user (SPEC §13.3 `user_emails`).

  Stored as `citext` so uniqueness is case-insensitive; at most one primary
  address per user (partial unique index).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "user_emails" do
    field :email, :string
    field :verified_at, :utc_datetime_usec
    field :primary, :boolean, default: false

    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(user_email, attrs) do
    user_email
    |> cast(attrs, [:email, :primary])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+\.[^@,;\s]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:email, max: 160)
    |> unique_constraint(:email)
    |> unique_constraint(:primary,
      name: :user_emails_one_primary_per_user_idx,
      message: "user already has a primary email"
    )
  end
end
