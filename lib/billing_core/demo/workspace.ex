defmodule BillingCore.Demo.Workspace do
  @moduledoc """
  Durable, synthetic Revryn demo workspace generation.

  A workspace is an ownership and progress record, not a billing shortcut:
  all commercial facts it eventually creates must use the ordinary contexts.
  """

  use Ecto.Schema

  alias BillingCore.Orgs.{Organization, Team}
  alias BillingCore.Identity.User

  @type t :: %__MODULE__{}
  @states [:provisioning, :active, :completed, :failed, :archived]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "demo_workspaces" do
    field :scenario_version, :string, default: "northstar-v1"
    field :generation, :integer
    field :state, Ecto.Enum, values: @states, default: :provisioning
    field :seed_key, :string
    field :progress, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :reset_at, :utc_datetime_usec

    belongs_to :team, Team
    belongs_to :organization, Organization
    belongs_to :owner, User, foreign_key: :owner_user_id
    belongs_to :predecessor_workspace, __MODULE__

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states
end
