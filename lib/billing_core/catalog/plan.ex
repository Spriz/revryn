defmodule BillingCore.Catalog.Plan do
  @moduledoc """
  Plan aggregate owning the stable team-scoped code (SPEC §13.3 `plans`,
  BC-US-013). Version content lives in `BillingCore.Catalog.PlanVersion`;
  `current_version` tracks the latest *published* version (0 until first
  publication).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.PlanVersion
  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "plans" do
    field :code, :string
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :current_version, :integer, default: 0

    belongs_to :team, Team
    has_many :versions, PlanVersion

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:code, :name])
    |> validate_required([:code, :name])
    |> validate_length(:code, max: 100)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_.-]*$/,
      message: "must be lowercase alphanumeric with `_`, `.`, `-`"
    )
    |> unique_constraint([:team_id, :code],
      error_key: :code,
      message: "code already used by another plan in this team"
    )
  end
end
