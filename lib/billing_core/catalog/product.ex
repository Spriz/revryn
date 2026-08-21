defmodule BillingCore.Catalog.Product do
  @moduledoc """
  Stable commercial product (SPEC §13.3 `products`, BC-US-010/011).

  The product row carries the mutable head (name, status, default
  recognition policy, `current_version`); every change is snapshotted as an
  immutable `BillingCore.Catalog.ProductVersion`. The code is unique per
  team and becomes immutable once any price component references the
  product.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "products" do
    field :code, :string
    field :name, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:active, :inactive], default: :active
    field :recognition_mode, Ecto.Enum, values: [:point_in_time, :over_time]

    field :service_period_source, Ecto.Enum,
      values: [:billing_period, :subscription_period, :explicit]

    field :approver_reference, :string
    field :approved_at, :utc_datetime_usec
    field :evidence_reference, :string
    field :current_version, :integer, default: 0

    belongs_to :team, Team

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @recognition_fields [
    :recognition_mode,
    :service_period_source,
    :approver_reference,
    :approved_at,
    :evidence_reference
  ]

  @doc false
  def create_changeset(product, attrs) do
    product
    |> cast(attrs, [:code, :name, :description | @recognition_fields])
    |> put_default(:recognition_mode, :point_in_time)
    |> validate_required([:code, :name, :recognition_mode])
    |> validate_length(:code, max: 100)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_.-]*$/,
      message: "must be lowercase alphanumeric with `_`, `.`, `-`"
    )
    |> validate_recognition()
    |> unique_constraint([:team_id, :code],
      error_key: :code,
      message: "code already used by another product in this team"
    )
  end

  @doc false
  def update_changeset(product, attrs) do
    product
    |> cast(attrs, [:code, :name, :description | @recognition_fields])
    |> validate_required([:code, :name, :recognition_mode])
    |> validate_length(:code, max: 100)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_.-]*$/,
      message: "must be lowercase alphanumeric with `_`, `.`, `-`"
    )
    |> validate_recognition()
    |> unique_constraint([:team_id, :code],
      error_key: :code,
      message: "code already used by another product in this team"
    )
  end

  # INV: `over_time` requires a service-period derivation rule (BC-US-011).
  defp validate_recognition(changeset) do
    case get_field(changeset, :recognition_mode) do
      :over_time ->
        validate_required(changeset, [:service_period_source],
          message: "is required for over_time recognition"
        )

      _mode ->
        changeset
    end
  end

  defp put_default(changeset, field, value) do
    if get_field(changeset, field), do: changeset, else: put_change(changeset, field, value)
  end
end
