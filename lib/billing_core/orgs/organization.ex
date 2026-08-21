defmodule BillingCore.Orgs.Organization do
  @moduledoc """
  Top-level administrative and commercial boundary (SPEC §9.1.1, §13.3
  `organizations`). An active organization always has at least one active
  team (INV-033).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "organizations" do
    field :slug, :string
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :security_policy, :map, default: %{}

    has_many :teams, Team

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:slug, :name, :security_policy])
    |> validate_required([:slug, :name])
    |> validate_length(:name, max: 200)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/,
      message: "must be lowercase letters, digits, and single dashes"
    )
    |> validate_length(:slug, max: 100)
    |> unique_constraint(:slug)
  end
end
