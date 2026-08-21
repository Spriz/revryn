defmodule BillingCore.ERP.Document do
  @moduledoc """
  Normalized external ERP document used for reconciliation (SPEC §17.14).

  Every provider read is normalized into this shape before comparison against
  the frozen invoice intent. Provider-generated VAT, gross totals, invoice
  numbers, and payment status are recorded in `provider_extras` but do not
  participate in pre-VAT matching unless team policy adds assertions.
  """

  alias BillingCore.Domain.Money

  @enforce_keys [:state, :external_reference, :currency, :invoice_date, :lines]
  defstruct [
    :state,
    :external_draft_id,
    :external_booked_number,
    :external_reference,
    :customer_external_id,
    :customer_snapshot_fingerprint,
    :recipient_fingerprint,
    :invoice_date,
    :currency,
    :payment_term_external_id,
    :layout_external_id,
    :lines,
    :external_hash,
    provider_extras: %{}
  ]

  @type line :: %{
          required(:order) => non_neg_integer(),
          required(:product_external_id) => String.t(),
          required(:amount) => Money.t(),
          required(:description_fingerprint) => String.t(),
          required(:recognition) =>
            :point_in_time | {:over_time, start :: Date.t(), end_exclusive :: Date.t()},
          optional(:description) => String.t()
        }

  @type t :: %__MODULE__{
          state: :draft | :booked,
          external_draft_id: String.t() | nil,
          external_booked_number: String.t() | nil,
          external_reference: String.t(),
          customer_external_id: String.t() | nil,
          customer_snapshot_fingerprint: String.t() | nil,
          recipient_fingerprint: String.t() | nil,
          invoice_date: Date.t(),
          currency: String.t(),
          payment_term_external_id: String.t() | nil,
          layout_external_id: String.t() | nil,
          lines: [line()],
          external_hash: String.t() | nil,
          provider_extras: map()
        }

  @doc "Net amount across normalized lines."
  @spec net_amount(t()) :: Money.t()
  def net_amount(%__MODULE__{currency: currency, lines: lines}) do
    lines
    |> Enum.map(& &1.amount)
    |> Money.sum!(currency)
  end
end
