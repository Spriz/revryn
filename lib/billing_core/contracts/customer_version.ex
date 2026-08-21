defmodule BillingCore.Contracts.CustomerVersion do
  @moduledoc """
  Immutable customer snapshot (SPEC §13.3 `customer_versions`, BC-US-030).

  Append-only at the database level; historical invoice intent references the
  exact version it was priced against. `snapshot` holds the canonical facts
  (including `status`) and `content_hash` its canonical SHA-256
  (`BillingCore.Domain.Canonical`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Contracts.Customer

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :legal_name, :string
    field :address_line, :string
    field :zip, :string
    field :city, :string
    field :country, :string
    field :email, :string
    field :vat_number, :string
    field :currency_preference, :string
    field :snapshot, :map
    field :content_hash, :string

    belongs_to :customer, Customer

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :legal_name,
      :address_line,
      :zip,
      :city,
      :country,
      :email,
      :vat_number,
      :currency_preference
    ])
    |> validate_required([:legal_name, :country, :email])
    |> validate_format(:country, ~r/^[A-Z]{2}$/, message: "must be a two-letter ISO 3166-1 code")
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must be a valid email")
    |> validate_format(:currency_preference, ~r/^[A-Z]{3}$/,
      message: "must be a three-letter ISO 4217 code"
    )
    |> unique_constraint([:team_id, :customer_id, :version])
  end
end
