defmodule BillingCore.Orgs.AccountTeamCustomer do
  @moduledoc """
  Projection of an organization account into one team's billing customer
  (SPEC §13.3 `account_team_customers`, BC-US-142). Unique per
  (account, team); `customer_id` intentionally carries no foreign key until
  the customer domain migration lands.
  """

  use Ecto.Schema

  alias BillingCore.Orgs.{Account, Team}

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "account_team_customers" do
    field :customer_id, Ecto.UUID

    belongs_to :account, Account
    belongs_to :team, Team

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end
end
