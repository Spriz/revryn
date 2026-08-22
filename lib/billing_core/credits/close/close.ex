defmodule BillingCore.Credits.Close.Close do
  @moduledoc """
  Persisted aggregate close for one team, currency, and half-open month.

  All amounts are integer minor units. `economic_liability_line_minor` is
  deliberately debit-positive: it is always `opening_minor - closing_minor`.
  """

  use Ecto.Schema

  alias BillingCore.Credits.Close.{Movement, PolicyVersion, TransactionMembership}

  @type t :: %__MODULE__{}

  @states [
    :open,
    :calculating,
    :ready,
    :approved,
    :posting,
    :outcome_unknown,
    :posted,
    :reconciled,
    :closed,
    :failed,
    :mismatch,
    :superseded,
    :reversal_pending,
    :reversed
  ]

  @schema_prefix "billing"
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "customer_credit_closes" do
    field :team_id, Ecto.UUID
    field :currency, :string
    field :period_start, :date
    field :period_end_exclusive, :date
    field :transaction_cutoff, :utc_datetime_usec
    field :state, Ecto.Enum, values: @states, default: :open

    field :close_kind, Ecto.Enum,
      values: [:regular, :reversal, :replacement],
      default: :regular

    field :opening_minor, :integer
    field :closing_minor, :integer
    field :net_change_minor, :integer
    field :economic_liability_line_minor, :integer
    field :ledger_transaction_count, :integer
    field :ledger_snapshot_hash, :string
    field :report_sha256, :string
    field :report_storage_key, :string
    field :operation_id, Ecto.UUID
    field :erp_document_id, Ecto.UUID
    field :closed_at, :utc_datetime_usec

    belongs_to :policy_version, PolicyVersion
    belongs_to :previous_close, __MODULE__
    belongs_to :reversal_of_close, __MODULE__
    has_many :movements, Movement
    has_many :transaction_memberships, TransactionMembership

    timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
  end

  @spec states() :: [atom()]
  def states, do: @states

  @spec exact_arithmetic?(t() | map()) :: boolean()
  def exact_arithmetic?(%{
        opening_minor: opening,
        closing_minor: closing,
        net_change_minor: net_change,
        economic_liability_line_minor: line
      })
      when is_integer(opening) and is_integer(closing) and is_integer(net_change) and
             is_integer(line) do
    opening >= 0 and closing >= 0 and net_change == closing - opening and
      line == opening - closing
  end

  def exact_arithmetic?(_), do: false
end
