defmodule BillingCore.Contracts.Subscription do
  @moduledoc """
  Subscription aggregate (SPEC §13.3 `subscriptions`, §11.1 state machine,
  BC-US-034…039).

  `status` persists the §11.1 machine state as a string; the effective
  plan/quantity history lives in non-overlapping
  `BillingCore.Contracts.SubscriptionVersion` rows, and every command is
  evidenced by an append-only `BillingCore.Contracts.SubscriptionChange`.
  `current_version` points at the latest version; `version` is the aggregate
  optimistic-concurrency counter (SPEC §13.1).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Contracts.Contract

  @type t :: %__MODULE__{}

  @statuses [:scheduled, :active, :paused, :pending_cancellation, :cancelled]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "subscriptions" do
    field :team_id, Ecto.UUID
    field :external_id, :string
    field :status, Ecto.Enum, values: @statuses
    field :start_date, :date
    field :end_date_exclusive, :date
    field :billing_anchor_day, :integer
    field :time_zone, :string
    field :current_version, :integer
    field :version, :integer, default: 1

    belongs_to :contract, Contract

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc "Persisted machine states (SPEC §11.1)."
  def statuses, do: @statuses

  @doc false
  def create_changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :external_id,
      :start_date,
      :end_date_exclusive,
      :billing_anchor_day,
      :time_zone
    ])
    |> validate_required([:external_id, :start_date, :time_zone])
    |> validate_length(:external_id, max: 200)
    |> validate_number(:billing_anchor_day,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 31
    )
    |> validate_half_open_period()
    |> unique_constraint([:team_id, :external_id],
      message: "external_id already used by another subscription in this team"
    )
    |> check_constraint(:start_date, name: :subscriptions_period_check)
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
