defmodule BillingCore.ERP.Adapter do
  @moduledoc """
  Adapter-neutral ERP port (SPEC §16).

  The domain depends only on this behaviour and the canonical structs in
  `BillingCore.ERP.CanonicalInvoice` / `BillingCore.ERP.Document`.
  Provider-specific fields are forbidden above the adapter boundary.

  Rules (SPEC §16.2):

    * adapters translate representation, never commercial meaning — they may
      not recalculate price, discount, proration, or recognition policy;
    * every external write receives an operation-specific idempotency key;
    * every external response is normalized before reconciliation;
    * an adapter may report an unsupported capability, but it must not emulate
      accounting behavior silently.

  Write callbacks return `{:unknown, recovery_hint}` when the request may have
  reached the provider but the outcome was lost (timeout after write). The
  caller must reconcile via `find_document/2` before any retry (INV-008/009).
  """

  alias BillingCore.ERP.{CanonicalInvoice, Document}
  alias BillingCore.ERP.Vouchers.{AttachmentEvidence, FinanceVoucher, Voucher}

  @type connection_context :: %{
          required(:connection_id) => Ecto.UUID.t(),
          required(:team_id) => Ecto.UUID.t(),
          required(:provider) => atom(),
          optional(:credentials) => term(),
          optional(atom()) => term()
        }

  @type capabilities :: %{
          supports_draft_invoices: boolean(),
          supports_draft_updates: boolean(),
          supports_booking: boolean(),
          supports_invoice_webhooks: boolean(),
          supports_line_accrual_periods: boolean(),
          supports_customer_provisioning: boolean(),
          supports_customer_credit_settlements: boolean(),
          supports_finance_vouchers: boolean(),
          supports_voucher_attachments: boolean(),
          supported_delivery_modes: [:none | :email | :einvoice],
          amount_scale: non_neg_integer(),
          quantity_scale: non_neg_integer()
        }

  @typedoc "Stable per-operation idempotency key (SPEC §17.7)."
  @type operation_key :: String.t()

  @typedoc "Stable external reference, unique per ERP connection (SPEC §17.4)."
  @type external_reference :: String.t()

  @type document_ref ::
          {:draft, String.t()}
          | {:booked, String.t()}
          | {:external_reference, external_reference()}

  @type voucher_ref ::
          {:voucher, String.t()}
          | {:external_reference, external_reference()}

  @type preflight_input :: %{
          optional(:product_external_ids) => [String.t()],
          optional(:customer_external_ids) => [String.t()],
          optional(:required_dates) => [Date.t()],
          optional(atom()) => term()
        }

  @type preflight_check :: %{
          check: atom(),
          status: :pass | :warn | :fail,
          detail: String.t()
        }

  @type preflight_result :: %{
          checks: [preflight_check()],
          capabilities: capabilities(),
          evidence: map()
        }

  @type booking_options :: %{
          required(:delivery_mode) => :none | :email | :einvoice,
          optional(atom()) => term()
        }

  @type recovery_hint :: %{
          optional(:search_by) => [document_ref()],
          optional(:retry_safe_after) => DateTime.t(),
          optional(:detail) => String.t()
        }

  @type error ::
          {:authentication, term()}
          | {:authorization, term()}
          | {:validation, [map()]}
          | {:not_found, term()}
          | {:conflict, term()}
          | {:rate_limited, %{retry_after: non_neg_integer() | nil}}
          | {:provider_failure, term()}
          | {:unsupported_capability, atom()}

  @callback capabilities(connection_context()) :: {:ok, capabilities()} | {:error, error()}

  @callback preflight(connection_context(), preflight_input()) ::
              {:ok, preflight_result()} | {:error, error()}

  @callback find_document(connection_context(), external_reference()) ::
              {:ok, Document.t() | nil} | {:error, error()}

  @callback create_draft(connection_context(), CanonicalInvoice.t(), operation_key()) ::
              {:ok, Document.t()} | {:unknown, recovery_hint()} | {:error, error()}

  @callback update_draft(
              connection_context(),
              document_ref(),
              CanonicalInvoice.t(),
              operation_key()
            ) :: {:ok, Document.t()} | {:unknown, recovery_hint()} | {:error, error()}

  @callback get_document(connection_context(), document_ref()) ::
              {:ok, Document.t()} | {:error, error()}

  @callback book_document(
              connection_context(),
              document_ref(),
              booking_options(),
              operation_key()
            ) :: {:ok, Document.t()} | {:unknown, recovery_hint()} | {:error, error()}

  @callback find_finance_voucher(connection_context(), external_reference()) ::
              {:ok, Voucher.t() | nil} | {:error, error()}

  @callback create_finance_voucher(connection_context(), FinanceVoucher.t(), operation_key()) ::
              {:ok, Voucher.t()} | {:unknown, recovery_hint()} | {:error, error()}

  @callback get_finance_voucher(connection_context(), voucher_ref()) ::
              {:ok, Voucher.t() | nil} | {:error, error()}

  @callback attach_voucher_report(
              connection_context(),
              voucher_ref(),
              AttachmentEvidence.t(),
              operation_key()
            ) :: :ok | {:unknown, recovery_hint()} | {:error, error()}

  @callback get_voucher_attachment(connection_context(), voucher_ref()) ::
              {:ok, AttachmentEvidence.t() | nil} | {:error, error()}
end
