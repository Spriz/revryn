defmodule BillingCore.Contracts.Contract do
  @moduledoc """
  Contract — commercial terms governing one or more subscriptions
  (SPEC §13.3 `contracts`, BC-US-033).

  One customer, one currency, half-open effective dates. Changes are
  append-only `BillingCore.Contracts.ContractVersion` snapshots.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Contracts.Customer

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "contracts" do
    field :team_id, Ecto.UUID
    field :external_reference, :string
    field :status, Ecto.Enum, values: [:draft, :active, :ended], default: :active
    field :currency, :string
    field :start_date, :date
    field :end_date_exclusive, :date
    field :current_version, :integer

    belongs_to :customer, Customer

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(contract, attrs) do
    contract
    |> cast(attrs, [:external_reference, :status, :currency, :start_date, :end_date_exclusive])
    |> validate_required([:external_reference, :currency, :start_date])
    |> validate_format(:currency, ~r/^[A-Z]{3}$/, message: "must be a three-letter ISO 4217 code")
    |> validate_half_open_period()
    |> unique_constraint([:team_id, :external_reference],
      message: "external_reference already used by another contract in this team"
    )
    |> check_constraint(:start_date, name: :contracts_period_check)
  end

  defp validate_half_open_period(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date_exclusive)

    if start_date && end_date && not Date.before?(start_date, end_date) do
      add_error(changeset, :end_date_exclusive, "must be after start_date")
    else
      changeset
    end
  end
end
