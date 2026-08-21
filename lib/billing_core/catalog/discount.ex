defmodule BillingCore.Catalog.Discount do
  @moduledoc """
  Discount aggregate owning the stable team-scoped code (SPEC §13.3
  `discounts`, BC-US-060/061/062). Definition content lives in immutable
  `BillingCore.Catalog.DiscountVersion` rows; `current_version` tracks the
  latest published version (0 until first publication).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.DiscountVersion
  alias BillingCore.Orgs.Team

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "discounts" do
    field :code, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :current_version, :integer, default: 0

    belongs_to :team, Team
    has_many :versions, DiscountVersion

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(discount, attrs) do
    discount
    |> cast(attrs, [:code])
    |> validate_required([:code])
    |> validate_length(:code, max: 100)
    |> validate_format(:code, ~r/^[a-z0-9][a-z0-9_.-]*$/,
      message: "must be lowercase alphanumeric with `_`, `.`, `-`"
    )
    |> unique_constraint([:team_id, :code],
      error_key: :code,
      message: "code already used by another discount in this team"
    )
  end
end
