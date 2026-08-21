defmodule BillingCore.Orgs.TeamSettingsVersion do
  @moduledoc """
  Immutable snapshot of a team's settings (SPEC §13.3
  `team_settings_versions`). `settings_hash` is the canonical SHA-256 of
  the settings map (`BillingCore.Domain.Canonical`); the table is
  append-only at the database level.
  """

  use Ecto.Schema

  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "team_settings_versions" do
    field :version, :integer
    field :settings, :map
    field :settings_hash, :string
    field :created_by, Ecto.UUID

    belongs_to :team, Team

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end
end
