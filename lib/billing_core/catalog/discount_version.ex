defmodule BillingCore.Catalog.DiscountVersion do
  @moduledoc """
  Immutable discount definition version (SPEC §13.3 `discount_versions`,
  BC-US-060/061/062). Append-only at the database.

  Exactly one field group is populated: `basis_points` (1..10000, i.e.
  >0% and <=100%) for `percentage`, or `amount_minor` (>0) + `currency`
  for `fixed_amount`.

  `eligible_scope` is either `%{"all" => true}` or a map with `"products"`
  and/or `"components"` code lists.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Catalog.Discount

  @type t :: %__MODULE__{}

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "discount_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :discount_type, Ecto.Enum, values: [:percentage, :fixed_amount]
    field :basis_points, :integer
    field :amount_minor, :integer
    field :currency, :string
    field :eligible_scope, :map, default: %{"all" => true}
    field :priority, :integer
    field :effective_from, :date
    field :effective_until_exclusive, :date
    field :max_billing_periods, :integer
    field :allocation_policy, :string, default: "proportional"
    field :content_hash, :string

    belongs_to :discount, Discount

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc false
  def changeset(discount_version, attrs) do
    discount_version
    |> cast(attrs, [
      :discount_type,
      :basis_points,
      :amount_minor,
      :currency,
      :eligible_scope,
      :priority,
      :effective_from,
      :effective_until_exclusive,
      :max_billing_periods,
      :allocation_policy
    ])
    |> validate_required([:discount_type, :priority, :effective_from, :allocation_policy])
    |> validate_type_fields()
    |> validate_eligible_scope()
    |> validate_number(:max_billing_periods, greater_than: 0)
    |> validate_inclusion(:allocation_policy, ["proportional", "explicit"])
    |> validate_effective_interval()
    |> unique_constraint([:team_id, :discount_id, :version],
      error_key: :version,
      message: "version already exists for this discount"
    )
  end

  # INV: exactly one of the percentage/fixed field groups is populated
  # (BC-US-060/061) — mirrored by the database CHECK constraint.
  defp validate_type_fields(changeset) do
    case get_field(changeset, :discount_type) do
      :percentage ->
        changeset
        |> validate_required([:basis_points])
        |> validate_number(:basis_points,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: 10_000
        )
        |> validate_absent(:amount_minor, "must be blank for percentage discounts")
        |> validate_absent(:currency, "must be blank for percentage discounts")

      :fixed_amount ->
        changeset
        |> validate_required([:amount_minor, :currency])
        |> validate_number(:amount_minor, greater_than: 0)
        |> validate_format(:currency, ~r/^[A-Z]{3}$/, message: "must be a 3-letter ISO 4217 code")
        |> validate_absent(:basis_points, "must be blank for fixed amount discounts")

      _type ->
        changeset
    end
  end

  defp validate_absent(changeset, field, message) do
    if is_nil(get_field(changeset, field)) do
      changeset
    else
      add_error(changeset, field, message)
    end
  end

  defp validate_eligible_scope(changeset) do
    case get_field(changeset, :eligible_scope) do
      %{"all" => true} = scope when map_size(scope) == 1 ->
        changeset

      %{} = scope ->
        keys_ok? =
          scope != %{} and Enum.all?(Map.keys(scope), &(&1 in ["products", "components"]))

        values_ok? = Enum.all?(Map.values(scope), &code_list?/1)

        if keys_ok? and values_ok? do
          changeset
        else
          add_error(
            changeset,
            :eligible_scope,
            ~s(must be %{"all" => true} or product/component code lists)
          )
        end

      _other ->
        add_error(changeset, :eligible_scope, "must be a map")
    end
  end

  defp code_list?(list), do: is_list(list) and list != [] and Enum.all?(list, &is_binary/1)

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
