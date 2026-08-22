defmodule BillingCore.Demo.FakeERPInstance do
  @moduledoc "Durable snapshot record for one demo workspace's fake ERP instance."

  use Ecto.Schema

  alias BillingCore.Demo.Workspace
  alias BillingCore.ERP.Connection
  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}
  @states [:active, :archived]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "fake_erp_instances" do
    field :snapshot, :binary
    field :snapshot_sha256, :string
    field :snapshot_format_version, :integer, default: 1
    field :lock_version, :integer, default: 1
    field :state, Ecto.Enum, values: @states, default: :active

    belongs_to :team, Team
    belongs_to :workspace, Workspace
    belongs_to :erp_connection, Connection

    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states
end
