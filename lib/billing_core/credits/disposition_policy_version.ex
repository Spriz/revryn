defmodule BillingCore.Credits.DispositionPolicyVersion do
  @moduledoc """
  Immutable credit disposition policy version (SPEC §13.3, BC-US-109,
  INV-053). Account-scoped in v1 (`account_id` NOT NULL — see the migration
  for the documented simplification); versions are append-only and existing
  grants keep the policy version assigned at creation unless explicitly
  migrated.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BillingCore.Orgs.Account

  @type t :: %__MODULE__{}

  @policies [:retain, :refund, :expire_after]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "credit_disposition_policy_versions" do
    field :team_id, Ecto.UUID
    field :contract_id, Ecto.UUID
    field :version, :integer
    field :policy, Ecto.Enum, values: @policies
    field :expire_after_days, :integer
    field :effective_from, :utc_datetime_usec
    field :created_by, Ecto.UUID

    belongs_to :account, Account

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Supported disposition policies (BC-US-109)."
  def policies, do: @policies

  @doc false
  def create_changeset(policy_version, attrs) do
    policy_version
    |> cast(attrs, [:contract_id, :policy, :expire_after_days, :effective_from])
    |> validate_required([:policy, :effective_from])
    |> validate_number(:expire_after_days, greater_than: 0)
    |> validate_expire_after_days()
    |> unique_constraint([:team_id, :account_id, :version],
      message: "policy version already exists for this account"
    )
  end

  defp validate_expire_after_days(changeset) do
    case {get_field(changeset, :policy), get_field(changeset, :expire_after_days)} do
      {:expire_after, nil} ->
        add_error(changeset, :expire_after_days, "is required for the expire_after policy")

      {policy, days} when policy != :expire_after and not is_nil(days) ->
        add_error(changeset, :expire_after_days, "is only allowed for the expire_after policy")

      _ ->
        changeset
    end
  end
end
