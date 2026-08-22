defmodule BillingCore.Contracts.ChargeInstance do
  @moduledoc """
  Idempotent one-time charge instance (SPEC §13.3 `charge_instances`,
  BC-US-041).

  Exactly one pricing source is authoritative: a published one-time
  `price_component_id` (with a positive quantity) or an explicit non-negative
  `amount_minor` (with quantity 1). `canonical_payload`/`payload_hash` freeze
  the creation command for replay comparison; cancellation is permitted only
  while `status` is `pending`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Contracts.{Contract, Subscription}

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "charge_instances" do
    field :team_id, Ecto.UUID
    field :external_id, :string
    field :product_id, Ecto.UUID
    field :product_version, :integer
    field :price_component_id, Ecto.UUID

    field :status, Ecto.Enum,
      values: [:pending, :frozen, :cancelled, :credited],
      default: :pending

    field :eligible_on, :date
    field :quantity, :decimal
    field :amount_minor, :integer
    field :currency, :string
    field :recognition_mode, Ecto.Enum, values: [:point_in_time, :over_time]
    field :service_start, :date
    field :service_end_exclusive, :date
    field :canonical_payload, :map
    field :payload_hash, :string

    belongs_to :contract, Contract
    belongs_to :subscription, Subscription

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(charge, attrs) do
    charge
    |> cast(attrs, [
      :external_id,
      :product_id,
      :product_version,
      :price_component_id,
      :eligible_on,
      :quantity,
      :amount_minor,
      :currency,
      :recognition_mode,
      :service_start,
      :service_end_exclusive
    ])
    |> validate_required([
      :external_id,
      :product_id,
      :product_version,
      :eligible_on,
      :quantity,
      :currency,
      :recognition_mode
    ])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:amount_minor, greater_than_or_equal_to: 0)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/, message: "must be a three-letter ISO 4217 code")
    |> validate_recognition_period()
    |> unique_constraint([:team_id, :external_id],
      message: "external_id already used by another charge instance in this team"
    )
    |> check_constraint(:recognition_mode, name: :charge_instances_recognition_check)
  end

  defp validate_recognition_period(changeset) do
    case get_field(changeset, :recognition_mode) do
      :over_time -> validate_over_time_period(changeset)
      :point_in_time -> validate_point_in_time_period(changeset)
      _missing -> changeset
    end
  end

  defp validate_over_time_period(changeset) do
    start_date = get_field(changeset, :service_start)
    end_date = get_field(changeset, :service_end_exclusive)

    cond do
      is_nil(start_date) or is_nil(end_date) ->
        add_error(
          changeset,
          :service_start,
          "over_time charges require a half-open service period"
        )

      not Date.before?(start_date, end_date) ->
        add_error(changeset, :service_end_exclusive, "must be after service_start")

      true ->
        changeset
    end
  end

  defp validate_point_in_time_period(changeset) do
    if get_field(changeset, :service_start) || get_field(changeset, :service_end_exclusive) do
      add_error(
        changeset,
        :service_start,
        "point_in_time charges must not carry a service period"
      )
    else
      changeset
    end
  end
end
