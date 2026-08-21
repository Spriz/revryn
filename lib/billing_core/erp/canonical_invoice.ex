defmodule BillingCore.ERP.CanonicalInvoice do
  @moduledoc """
  Adapter-neutral canonical invoice sent to an ERP (SPEC §16.1).

  Contains only domain-level values: stable references, document type, frozen
  customer identity snapshot, invoice date, currency, payment/layout mapping
  references, delivery mode, and normalized lines. Monetary values are integer
  minor units plus currency; quantities and rates are `Decimal`. Provider
  field names exist only inside concrete adapters.
  """

  alias BillingCore.Domain.{Money, Period}
  alias BillingCore.ERP.CanonicalInvoice.Line

  @enforce_keys [
    :external_reference,
    :document_type,
    :customer_external_id,
    :recipient,
    :invoice_date,
    :currency,
    :lines
  ]
  defstruct [
    :external_reference,
    :document_type,
    :customer_external_id,
    :recipient,
    :invoice_date,
    :currency,
    :payment_term_external_id,
    :layout_external_id,
    :lines,
    delivery_mode: :none
  ]

  @type recipient :: %{
          required(:legal_name) => String.t(),
          optional(:address) => String.t() | nil,
          optional(:zip) => String.t() | nil,
          optional(:city) => String.t() | nil,
          optional(:country) => String.t() | nil,
          optional(:email) => String.t() | nil,
          optional(:vat_number) => String.t() | nil,
          optional(:vat_zone_external_id) => String.t() | nil
        }

  @type t :: %__MODULE__{
          external_reference: String.t(),
          document_type: :invoice | :credit_note,
          customer_external_id: String.t(),
          recipient: recipient(),
          invoice_date: Date.t(),
          currency: String.t(),
          payment_term_external_id: String.t() | nil,
          layout_external_id: String.t() | nil,
          delivery_mode: :none | :email | :einvoice,
          lines: [Line.t()]
        }

  defmodule Line do
    @moduledoc """
    Normalized invoice line for the ERP boundary.

    The final calculated amount is authoritative; adapters render it as
    `quantity=1 × unitNetPrice=amount` so the ERP total reconciles exactly in
    minor units (SPEC §17.5, BC-US-090). The original quantity and effective
    rate travel in the description and the retained calculation trace.
    """

    @enforce_keys [:order, :line_key, :product_external_id, :description, :amount, :recognition]
    defstruct [
      :order,
      :line_key,
      :product_external_id,
      :description,
      :amount,
      :recognition,
      :source_quantity,
      :source_unit
    ]

    @type recognition :: :point_in_time | {:over_time, Period.t()}

    @type t :: %__MODULE__{
            order: non_neg_integer(),
            line_key: String.t(),
            product_external_id: String.t(),
            description: String.t(),
            amount: Money.t(),
            recognition: recognition(),
            source_quantity: Decimal.t() | nil,
            source_unit: String.t() | nil
          }
  end

  @doc "Net amount across all lines in minor units."
  @spec net_amount(t()) :: Money.t()
  def net_amount(%__MODULE__{currency: currency, lines: lines}) do
    lines
    |> Enum.map(& &1.amount)
    |> Money.sum!(currency)
  end
end
