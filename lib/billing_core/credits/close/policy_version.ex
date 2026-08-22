defmodule BillingCore.Credits.Close.PolicyVersion do
  @moduledoc """
  Immutable accounting policy snapshot for a customer-credit close.

  A close holds the policy version ID, rather than copying mutable account
  mappings, so its report and voucher can always be audited against the exact
  finance configuration that was approved.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  @posting_modes [:single_offset, :movement_class]
  @settlement_modes [:none, :erp_customer_settlement, :external_reference]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_close_policy_versions" do
    field :team_id, Ecto.UUID
    field :version, :integer
    field :effective_from, :date
    field :journal_number, :integer
    field :liability_account_number, :integer
    field :posting_mode, Ecto.Enum, values: @posting_modes
    field :default_offset_account_number, :integer
    field :movement_account_map, :map, default: %{}
    field :post_zero_delta, :boolean, default: false
    field :vat_neutral, :boolean, default: true

    # SPEC §9.4.1: which system owns open receivables. Automatic credit
    # application is blocked while the current policy says `:none`.
    field :settlement_mode, Ecto.Enum, values: @settlement_modes, default: :none
    field :settlement_clearing_account_number, :integer
    field :settlement_contra_account_number, :integer
    field :created_by, Ecto.UUID

    timestamps(inserted_at: :created_at, updated_at: false, type: :utc_datetime_usec)
  end

  @spec posting_modes() :: [atom()]
  def posting_modes, do: @posting_modes

  @spec settlement_modes() :: [atom()]
  def settlement_modes, do: @settlement_modes
end
