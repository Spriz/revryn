defmodule BillingCore.Credits.CreditGrant do
  @moduledoc """
  Customer-credit grant (SPEC §13.3 `customer_credit_grants`, §11.4,
  BC-US-107): immutable original value with explicit origin, plus the
  mutable §11.4 lifecycle projection (`status`, `remaining_minor`,
  `reserved_minor`) derived from the append-only ledger. Status changes are
  validated against `BillingCore.Credits.grant_machine/0`.
  """

  use Ecto.Schema

  alias BillingCore.Credits.CreditAccount

  @type t :: %__MODULE__{}

  @origin_types ~w(unused_prepaid_service goodwill external_correction manual)
  @statuses [
    :available,
    :reserved,
    :partially_spent,
    :spent,
    :refund_pending,
    :refunded,
    :expiry_scheduled,
    :expired
  ]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_grants" do
    field :team_id, Ecto.UUID
    field :origin_type, :string
    field :origin_id, Ecto.UUID
    field :origin_invoice_line_id, Ecto.UUID
    field :granted_minor, :integer
    field :currency, :string
    field :granted_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :disposition_policy_version_id, Ecto.UUID
    field :metadata, :map, default: %{}

    field :status, Ecto.Enum, values: @statuses, default: :available
    field :remaining_minor, :integer
    field :reserved_minor, :integer, default: 0
    field :version, :integer, default: 1

    belongs_to :credit_account, CreditAccount

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @doc "Valid `origin_type` values (BC-US-107)."
  def origin_types, do: @origin_types

  @doc "§11.4 projection states."
  def statuses, do: @statuses

  @doc "Unreserved spendable remainder of this grant, in minor units."
  @spec headroom(t()) :: integer()
  def headroom(%__MODULE__{remaining_minor: remaining, reserved_minor: reserved}) do
    remaining - reserved
  end
end
