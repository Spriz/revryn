defmodule BillingCore.Identity.User do
  @moduledoc """
  Global authentication identity (SPEC §9.1.1, §13.3 `users`).

  A user is not owned by any organization and stores no organization/team
  role. Authorization comes exclusively from explicit membership rows;
  `platform_admin` covers deployment administration only and never grants
  business-data access (SPEC §6.3).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.UserEmail

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "users" do
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :platform_admin, :boolean, default: false

    has_many :emails, UserEmail

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:status, :platform_admin])
    |> validate_required([:status, :platform_admin])
  end
end
