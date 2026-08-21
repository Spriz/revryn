defmodule BillingCore.Orgs.Account do
  @moduledoc """
  Organization-scoped commercial B2B customer identity shared across teams
  (SPEC §9.1.1, §13.3 `accounts`, BC-US-142). Team-local billing
  projections are held in `account_team_customers`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Orgs.Organization

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "accounts" do
    field :external_id, :string
    field :display_name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :metadata, :map, default: %{}

    belongs_to :organization, Organization

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(account, attrs) do
    account
    |> cast(attrs, [:external_id, :display_name, :metadata])
    |> validate_required([:external_id, :display_name])
    |> validate_length(:external_id, max: 200)
    |> validate_length(:display_name, max: 200)
    |> unique_constraint([:organization_id, :external_id],
      message: "external_id already used by another account in this organization"
    )
  end

  @doc false
  def update_changeset(account, attrs) do
    account
    |> cast(attrs, [:display_name, :metadata])
    |> validate_required([:display_name])
    |> validate_length(:display_name, max: 200)
  end
end
