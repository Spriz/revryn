defmodule BillingCore.ERP.Vouchers.FinanceVoucherLine do
  @moduledoc """
  One aggregate, VAT-neutral journal line in a canonical finance voucher.

  `amount` uses the canonical debit-positive convention.  The line deliberately
  has no customer, invoice, VAT, or product dimension: credit-close vouchers
  are general-ledger aggregates, never a copy of the credit subledger.
  """

  alias BillingCore.Domain.Money

  @enforce_keys [:line_key, :account_external_id, :amount, :role]
  defstruct [:line_key, :account_external_id, :amount, :role, :description]

  @type role ::
          :customer_credit_liability | :balancing | :settlement_clearing | :settlement_contra

  @type t :: %__MODULE__{
          line_key: String.t(),
          account_external_id: String.t(),
          amount: Money.t(),
          role: role(),
          description: String.t() | nil
        }
end
