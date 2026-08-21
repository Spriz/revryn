defmodule BillingCore.Catalog.DiscountAssignment do
  @moduledoc """
  Attachment of one immutable discount version to exactly one contract or
  subscription for an effective interval (SPEC §13.3 `discount_assignments`).

  Assignments may be deactivated prospectively (status + a shortened
  `effective_until_exclusive`) but are never rewritten retroactively.
  `contract_id`/`subscription_id` are plain uuids — those tables are owned
  by the contracts context.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.DiscountVersion

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "discount_assignments" do
    field :team_id, Ecto.UUID
    field :contract_id, Ecto.UUID
    field :subscription_id, Ecto.UUID
    field :status, Ecto.Enum, values: [:active, :deactivated], default: :active
    field :effective_from, :date
    field :effective_until_exclusive, :date

    belongs_to :discount_version, DiscountVersion

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:contract_id, :subscription_id, :effective_from, :effective_until_exclusive])
    |> validate_required([:effective_from])
    |> validate_exactly_one_target()
    |> validate_effective_interval()
  end

  # INV: scope is explicit — exactly one target (BC-US-060).
  defp validate_exactly_one_target(changeset) do
    contract_id = get_field(changeset, :contract_id)
    subscription_id = get_field(changeset, :subscription_id)

    case {contract_id, subscription_id} do
      {nil, nil} ->
        add_error(changeset, :contract_id, "exactly one of contract or subscription is required")

      {_contract, nil} ->
        changeset

      {nil, _subscription} ->
        changeset

      {_contract, _subscription} ->
        add_error(changeset, :contract_id, "cannot target both a contract and a subscription")
    end
  end

  defp validate_effective_interval(changeset) do
    from = get_field(changeset, :effective_from)
    until = get_field(changeset, :effective_until_exclusive)

    if is_struct(from, Date) and is_struct(until, Date) and Date.compare(from, until) != :lt do
      add_error(changeset, :effective_until_exclusive, "must be after effective_from")
    else
      changeset
    end
  end
end
