defmodule BillingCore.Catalog.PlanVersion do
  @moduledoc """
  One version of a plan (SPEC §13.3 `plan_versions`, BC-US-013/014).

  Drafts are mutable and deletable. Publication freezes the version: the
  database trigger `billing.protect_published_plan_version()` rejects every
  UPDATE on a published row except the retirement transition, and only
  drafts may be deleted. `definition` holds the serialized canonical
  publication snapshot and `content_hash` its canonical SHA-256.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.{Plan, PriceComponent}

  @type t :: %__MODULE__{}

  # Whole-month interval counts per SPEC §9.5.
  @month_counts [1, 2, 3, 4, 6, 12]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "plan_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :status, Ecto.Enum, values: [:draft, :published, :retired], default: :draft
    field :currency, :string
    field :interval_unit, Ecto.Enum, values: [:month, :day]
    field :interval_count, :integer
    field :billing_timing, Ecto.Enum, values: [:in_advance, :in_arrears]
    field :effective_from, :date
    field :definition, :map, default: %{}
    field :content_hash, :string
    field :published_at, :utc_datetime_usec
    field :published_by, Ecto.UUID

    belongs_to :plan, Plan
    has_many :price_components, PriceComponent

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def draft_changeset(plan_version, attrs) do
    plan_version
    |> cast(attrs, [:currency, :interval_unit, :interval_count, :billing_timing, :effective_from])
    |> validate_required([:currency, :interval_unit, :interval_count, :billing_timing])
    |> validate_format(:currency, ~r/^[A-Z]{3}$/, message: "must be a 3-letter ISO 4217 code")
    |> validate_interval()
    |> unique_constraint([:team_id, :plan_id, :version],
      error_key: :version,
      message: "version already exists for this plan"
    )
  end

  # SPEC §9.5: whole-month intervals use counts 1|2|3|4|6|12; day intervals
  # any positive count (never to approximate months).
  defp validate_interval(changeset) do
    count = get_field(changeset, :interval_count)

    case get_field(changeset, :interval_unit) do
      :month when is_integer(count) and count not in @month_counts ->
        add_error(changeset, :interval_count, "must be one of #{inspect(@month_counts)} months")

      :day ->
        validate_number(changeset, :interval_count, greater_than: 0)

      _unit ->
        changeset
    end
  end
end
