defmodule BillingCore.Privacy do
  @moduledoc """
  Customer erasure/pseudonymization (SPEC §20).

  A deletion request pseudonymizes the customer's operational personal
  data going forward by appending a redacted immutable version through the
  ordinary customer command — the same append-only history every other
  change uses. Historical version snapshots and frozen invoice evidence
  are financial evidence: they are retained (or redacted only through the
  accountant-approved policy in `docs/accounting/retention.md`), so close
  continuity and voucher traceability never break. Every erasure is
  audited and emitted as a domain event.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Contracts, Outbox, Repo, Scope}
  alias BillingCore.Contracts.Customer

  @doc """
  Pseudonymizes a customer's operational data (team admins only).

  Refused while the customer still has live subscriptions
  (`{:error, :active_subscriptions}`) — contractual retention needs come
  first (SPEC §20). Returns the updated customer plus the list of retained
  evidence classes for the requester's records.
  """
  @spec erase_customer(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, %{customer: Customer.t(), retained: [atom()]}} | {:error, term()}
  def erase_customer(%Scope{} = scope, customer_id, reason) when is_binary(reason) do
    with :ok <- authorize(scope),
         :ok <- ensure_reason(reason),
         {:ok, customer} <- Contracts.get_customer(scope, customer_id),
         :ok <- ensure_no_live_subscriptions(customer) do
      short = String.slice(customer.id, 0, 8)

      {:ok, %{customer: erased}} =
        Contracts.upsert_customer(scope, %{
          external_id: customer.external_id,
          legal_name: "Erased customer #{short}",
          address_line: nil,
          zip: nil,
          city: nil,
          country: "ZZ",
          email: "erased+#{short}@anonymized.invalid",
          vat_number: nil,
          currency_preference: nil
        })

      retained = [:customer_version_history, :frozen_invoice_evidence, :audit_log]

      Audit.record!(scope, "privacy.customer_erased",
        aggregate: {:customer, erased.id},
        payload: %{reason: reason, retained: retained}
      )

      Outbox.emit!("customer.erased.v1",
        aggregate: {:customer, erased.id},
        team_id: erased.team_id,
        correlation_id: scope.correlation_id,
        payload: %{external_id: erased.external_id, retained: retained}
      )

      {:ok, %{customer: erased, retained: retained}}
    end
  end

  defp authorize(scope) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, [:team_admin]),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp ensure_reason(reason) do
    if String.trim(reason) == "", do: {:error, :reason_required}, else: :ok
  end

  defp ensure_no_live_subscriptions(%Customer{} = customer) do
    contract_ids =
      Repo.all(
        from c in "contracts",
          prefix: "billing",
          where: c.customer_id == type(^customer.id, Ecto.UUID),
          select: c.id
      )

    live? =
      contract_ids != [] and
        Repo.exists?(
          from s in "subscriptions",
            prefix: "billing",
            where: s.contract_id in ^contract_ids and s.status != "cancelled"
        )

    if live?, do: {:error, :active_subscriptions}, else: :ok
  end
end
