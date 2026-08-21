defmodule BillingCore.Orgs.OrganizationMembership do
  @moduledoc """
  Explicit user-to-organization grant carrying organization-local roles
  (SPEC §6.3, §13.3). At most one ACTIVE membership per (organization,
  user); role grants never leak into teams.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Identity.User
  alias BillingCore.Orgs.Organization

  @type t :: %__MODULE__{}

  @roles [:organization_owner, :organization_admin, :organization_member]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "organization_memberships" do
    field :roles, {:array, Ecto.Enum}, values: @roles
    field :status, Ecto.Enum, values: [:active, :suspended, :removed], default: :active

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc "Canonical organization roles (SPEC §6.3)."
  @spec roles() :: [atom()]
  def roles, do: @roles

  @doc false
  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:roles, :status])
    |> validate_required([:roles, :status])
    |> validate_length(:roles, min: 1)
    |> unique_constraint([:organization_id, :user_id],
      name: :organization_memberships_one_active_idx,
      message: "user already has an active membership in this organization"
    )
  end
end
