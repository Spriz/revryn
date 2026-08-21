defmodule BillingCore.Orgs.TeamMembership do
  @moduledoc """
  Explicit user-to-team grant carrying team-local roles (SPEC §6.3, §13.3).

  The team determines the organization; an active team membership requires
  an active membership in the owning organization (enforced by
  `BillingCore.Orgs`). Team roles never derive from organization roles.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User
  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}

  @roles [:team_admin, :billing_admin, :finance_operator, :auditor, :integration_client]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "team_memberships" do
    field :roles, {:array, Ecto.Enum}, values: @roles
    field :status, Ecto.Enum, values: [:active, :suspended, :removed], default: :active

    belongs_to :team, Team
    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc "Canonical team roles (SPEC §6.3)."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:roles, :status])
    |> validate_required([:roles, :status])
    |> validate_length(:roles, min: 1)
    |> unique_constraint([:team_id, :user_id],
      name: :team_memberships_one_active_idx,
      message: "user already has an active membership in this team"
    )
  end
end
