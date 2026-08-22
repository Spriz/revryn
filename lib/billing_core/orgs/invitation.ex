defmodule BillingCore.Orgs.Invitation do
  @moduledoc """
  A single-use, expiring, hashed-at-rest invitation to organization/team
  memberships (BC-US-144). The raw token exists only in the moment of
  creation; only its SHA-256 is stored.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false]

  schema "organization_invitations" do
    field :organization_id, Ecto.UUID
    field :team_id, Ecto.UUID
    field :email, :string
    field :organization_roles, {:array, :string}, default: []
    field :team_roles, {:array, :string}, default: []
    field :token_hash, :string
    field :invited_by, Ecto.UUID
    field :expires_at, :utc_datetime_usec
    field :accepted_at, :utc_datetime_usec
    field :accepted_user_id, Ecto.UUID
    field :revoked_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
  end

  @doc "Pending = not accepted, not revoked, not expired."
  @spec pending?(t :: %__MODULE__{}, DateTime.t()) :: boolean()
  def pending?(%__MODULE__{} = invitation, %DateTime{} = now) do
    is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at) and
      DateTime.after?(invitation.expires_at, now)
  end
end
