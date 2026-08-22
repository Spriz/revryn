defmodule BillingCore.ERP.Vouchers.Voucher do
  @moduledoc """
  Normalized authoritative finance-voucher read-back from an ERP provider.
  """

  alias BillingCore.ERP.Vouchers.FinanceVoucherLine

  @enforce_keys [
    :external_voucher_number,
    :external_reference,
    :accounting_date,
    :accounting_year_external_id,
    :journal_external_id,
    :currency,
    :lines
  ]
  defstruct [
    :external_voucher_number,
    :external_reference,
    :accounting_date,
    :accounting_year_external_id,
    :journal_external_id,
    :currency,
    :lines,
    :external_hash,
    provider_extras: %{}
  ]

  @type t :: %__MODULE__{
          external_voucher_number: String.t(),
          external_reference: String.t(),
          accounting_date: Date.t(),
          accounting_year_external_id: String.t(),
          journal_external_id: String.t(),
          currency: String.t(),
          lines: [FinanceVoucherLine.t()],
          external_hash: String.t() | nil,
          provider_extras: map()
        }
end
