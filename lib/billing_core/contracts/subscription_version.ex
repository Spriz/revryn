defmodule BillingCore.Contracts.SubscriptionVersion do
  @moduledoc """
  Subscription version snapshot (SPEC §13.3 `subscription_versions`): plan
  version, quantity, effective period, price overrides, cancellation policy,
  and status reason.

  Versions form a non-overlapping half-open timeline per subscription —
  enforced by the `subscription_versions_no_overlap` exclusion constraint.
  A superseding change closes the current version's
  `effective_end_exclusive` at the effective date and appends the next
  version; nothing else about a version is ever rewritten.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Contracts.Subscription

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "subscription_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :plan_version_id, Ecto.UUID
    field :quantity, :decimal
    field :effective_start, :date
    field :effective_end_exclusive, :date
    field :price_overrides, :map, default: %{}
    field :cancellation_policy, :string, default: "end_of_period"
    field :status_reason, :string

    belongs_to :subscription, Subscription

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :plan_version_id,
      :quantity,
      :effective_start,
      :effective_end_exclusive,
      :price_overrides,
      :cancellation_policy,
      :status_reason
    ])
    |> validate_required([:plan_version_id, :quantity, :effective_start])
    |> validate_number(:quantity, greater_than: 0)
    |> unique_constraint([:team_id, :subscription_id, :version])
    |> check_constraint(:quantity, name: :subscription_versions_quantity_check)
    |> check_constraint(:effective_start, name: :subscription_versions_period_check)
    |> exclusion_constraint(:effective_start,
      name: :subscription_versions_no_overlap,
      message: "overlaps another version of this subscription"
    )
  end
end
