defmodule BillingCore.Orgs.Team do
  @moduledoc """
  Team — child of exactly one organization and the hard billing/accounting/
  authorization isolation boundary (SPEC §9.1.1, §13.3 `teams`).

  All team-owned rows use the immutable team UUID, never the mutable name or
  slug, as their ownership key. The bootstrap name `Default` is a
  convenience only — code must never branch on it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Orgs.Organization

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "teams" do
    field :name, :string
    field :slug, :string
    field :legal_name, :string
    field :base_currency, :string
    field :time_zone, :string
    field :locale, :string
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :settings_version, :integer, default: 1

    belongs_to :organization, Organization

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :slug, :legal_name, :base_currency, :time_zone, :locale])
    |> validate_required([:name, :slug, :legal_name, :base_currency, :time_zone, :locale])
    |> validate_length(:name, max: 200)
    |> validate_format(:slug, ~r/^[a-z0-9]+(-[a-z0-9]+)*$/,
      message: "must be lowercase letters, digits, and single dashes"
    )
    |> validate_length(:slug, max: 100)
    |> validate_format(:base_currency, ~r/^[A-Z]{3}$/,
      message: "must be a three-letter ISO 4217 code"
    )
    |> unique_constraint([:organization_id, :slug],
      message: "slug already used by another team in this organization"
    )
  end

  @doc false
  def rename_changeset(team, attrs) do
    team
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
  end
end
