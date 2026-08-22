defmodule BillingCore.Credits.Settlements do
  @moduledoc """
  Receivable settlement of credit-covered invoice amounts (SPEC §9.4.1,
  BC-US-108).

  The currently effective close posting-policy version declares the
  receivable-settlement mode. While it is `:none` (or no policy exists),
  automatic credit application is blocked — the system refuses rather than
  netting an invoice silently. Each credit application inserts exactly one
  settlement record in the freeze transaction:

    * `:erp_customer_settlement` — when the invoice books in the ERP, a
      durable operation posts a two-line clearing voucher (debit the
      accountant-approved clearing account, credit the contra account) and
      reconciles it by read-back before the settlement becomes terminal;
    * `:external_reference` — the authoritative external receivables
      system settles the invoice; its reference is recorded exactly once
      via `record_external_settlement/3`.

  The monthly aggregate liability close never marks an invoice paid; the
  settlement record is the drill-down that proves the clearing account
  reconciles.
  """

  import Ecto.Query

  alias BillingCore.{Audit, ERP, Operations, Outbox, Repo, Scope}
  alias BillingCore.Credits.Close.PolicyVersion
  alias BillingCore.Credits.{CreditAccount, CreditSettlement}
  alias BillingCore.Domain.{Canonical, Money}
  alias BillingCore.ERP.{ErpDocument, SyncOperation}
  alias BillingCore.ERP.Vouchers.{FinanceVoucher, FinanceVoucherLine}

  @read_roles [:finance_operator, :billing_admin, :team_admin, :auditor, :integration_client]
  @write_roles [:finance_operator, :billing_admin, :team_admin]

  @doc """
  The team's currently effective close posting-policy version, or `nil`.
  """
  @spec current_policy(Ecto.UUID.t()) :: PolicyVersion.t() | nil
  def current_policy(team_id) do
    today = Date.utc_today()

    Repo.one(
      from policy in PolicyVersion,
        where: policy.team_id == ^team_id and policy.effective_from <= ^today,
        order_by: [desc: policy.effective_from, desc: policy.version],
        limit: 1
    )
  end

  @doc """
  The certified receivable-settlement mode for a team: `{:none, nil}` until
  an effective policy declares one (SPEC §9.4.1 certification gate).
  """
  @spec settlement_mode(Ecto.UUID.t()) :: {atom(), PolicyVersion.t() | nil}
  def settlement_mode(team_id) do
    case current_policy(team_id) do
      nil -> {:none, nil}
      policy -> {policy.settlement_mode, policy}
    end
  end

  @doc """
  Records the settlement for one credit application, inside the freeze
  transaction. Raises `Ecto.Repo` rollback `:settlement_mode_not_configured`
  when no mode is certified — freezing with credit applied must never
  succeed silently without a settlement path.
  """
  @spec record_application!(
          Scope.t(),
          Ecto.UUID.t(),
          CreditAccount.t(),
          pos_integer(),
          String.t()
        ) ::
          CreditSettlement.t()
  def record_application!(
        %Scope{} = scope,
        invoice_intent_id,
        %CreditAccount{} = account,
        amount_minor,
        currency
      )
      when is_integer(amount_minor) and amount_minor > 0 do
    case settlement_mode(Scope.team_id!(scope)) do
      {:none, _policy} ->
        Repo.rollback(:settlement_mode_not_configured)

      {mode, policy} ->
        settlement =
          Repo.insert!(%CreditSettlement{
            team_id: Scope.team_id!(scope),
            invoice_intent_id: invoice_intent_id,
            credit_account_id: account.id,
            policy_version_id: policy.id,
            currency: currency,
            amount_minor: amount_minor,
            mode: mode,
            state: :pending
          })

        Audit.record!(scope, "credits.settlement.opened",
          aggregate: {:customer_credit_settlement, settlement.id},
          payload: %{
            invoice_intent_id: invoice_intent_id,
            amount_minor: amount_minor,
            currency: currency,
            mode: mode
          }
        )

        settlement
    end
  end

  @doc """
  Booking hook: when an invoice intent reconciles as booked, its pending
  `erp_customer_settlement` (if any) gets a durable posting operation.
  Runs inside the booking-reconciliation transaction; idempotent — a
  settlement that already carries an operation is left alone.
  """
  @spec enqueue_for_booked_intent!(ErpDocument.t()) :: :ok
  def enqueue_for_booked_intent!(%ErpDocument{invoice_intent_id: intent_id} = doc)
      when is_binary(intent_id) do
    settlement =
      Repo.one(
        from s in CreditSettlement,
          where:
            s.invoice_intent_id == ^intent_id and s.mode == :erp_customer_settlement and
              s.state == :pending and is_nil(s.operation_id),
          lock: "FOR UPDATE"
      )

    case settlement do
      nil -> :ok
      settlement -> enqueue_posting!(settlement, doc)
    end
  end

  def enqueue_for_booked_intent!(_doc), do: :ok

  @doc """
  Records the authoritative external receivables system's settlement
  reference and reconciles the settlement (mode `:external_reference`).
  """
  @spec record_external_settlement(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, CreditSettlement.t()} | {:error, term()}
  def record_external_settlement(%Scope{} = scope, settlement_id, external_reference)
      when is_binary(external_reference) do
    with :ok <- authorize(scope, @write_roles),
         :ok <- ensure_presence(external_reference) do
      Repo.transaction(fn ->
        settlement =
          Repo.one(
            from s in CreditSettlement,
              where: s.id == ^settlement_id and s.team_id == ^Scope.team_id!(scope),
              lock: "FOR UPDATE"
          ) || Repo.rollback(:not_found)

        cond do
          settlement.mode != :external_reference ->
            Repo.rollback(:not_external_mode)

          settlement.state == :reconciled ->
            # Reconciled exactly once: replays with the same reference are
            # idempotent, a different reference is a conflict.
            if settlement.external_reference == external_reference,
              do: settlement,
              else: Repo.rollback(:already_reconciled)

          true ->
            reconciled =
              settlement
              |> Ecto.Changeset.change(
                state: :reconciled,
                external_reference: external_reference,
                reconciled_at: DateTime.utc_now()
              )
              |> Repo.update!()

            Audit.record!(scope, "credits.settlement.reconciled",
              aggregate: {:customer_credit_settlement, reconciled.id},
              payload: %{external_reference: external_reference, mode: :external_reference}
            )

            Outbox.emit!("customer_credit_settlement.reconciled.v1",
              aggregate: {:customer_credit_settlement, reconciled.id},
              team_id: reconciled.team_id,
              correlation_id: scope.correlation_id,
              payload: %{
                invoice_intent_id: reconciled.invoice_intent_id,
                amount_minor: reconciled.amount_minor,
                currency: reconciled.currency,
                external_reference: external_reference
              }
            )

            reconciled
        end
      end)
    end
  end

  @doc "Settlements of the scope's team, newest first (finance read roles)."
  @spec list_settlements(Scope.t(), keyword()) ::
          {:ok, [CreditSettlement.t()]} | {:error, :unauthorized}
  def list_settlements(%Scope{} = scope, filters \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      query =
        from s in CreditSettlement,
          where: s.team_id == ^Scope.team_id!(scope),
          order_by: [desc: s.created_at],
          limit: 200

      query =
        case filters[:invoice_intent_id] do
          nil -> query
          intent_id -> from s in query, where: s.invoice_intent_id == ^intent_id
        end

      query =
        case filters[:state] do
          state when state in [:pending, :reconciled] -> from s in query, where: s.state == ^state
          _other -> query
        end

      {:ok, Repo.all(query)}
    end
  end

  @doc """
  The canonical two-line clearing voucher for one settlement: debit the
  clearing account, credit the contra account (both accountant-approved on
  the policy version). Deterministic for the same settlement.
  """
  @spec build_settlement_voucher(CreditSettlement.t(), PolicyVersion.t(), Date.t()) ::
          {:ok, FinanceVoucher.t()} | {:error, term()}
  def build_settlement_voucher(
        %CreditSettlement{} = settlement,
        %PolicyVersion{} = policy,
        %Date{} = accounting_date
      ) do
    voucher = %FinanceVoucher{
      external_reference: external_reference(settlement),
      accounting_date: accounting_date,
      accounting_year_external_id: Integer.to_string(accounting_date.year),
      journal_external_id: Integer.to_string(policy.journal_number),
      currency: settlement.currency,
      lines: [
        %FinanceVoucherLine{
          line_key: "settlement-clearing",
          account_external_id: to_string(policy.settlement_clearing_account_number),
          amount: Money.new!(settlement.currency, settlement.amount_minor),
          role: :settlement_clearing,
          description: "Customer-credit settlement #{settlement.invoice_intent_id}"
        },
        %FinanceVoucherLine{
          line_key: "settlement-contra",
          account_external_id: to_string(policy.settlement_contra_account_number),
          amount: Money.new!(settlement.currency, -settlement.amount_minor),
          role: :settlement_contra,
          description: "Customer-credit settlement contra #{settlement.invoice_intent_id}"
        }
      ],
      vat_neutral: true
    }

    case FinanceVoucher.validate(voucher) do
      :ok -> {:ok, voucher}
      {:error, errors} -> {:error, {:invalid_finance_voucher, errors}}
    end
  end

  @doc false
  def external_reference(%CreditSettlement{id: id}), do: "credit-settlement:#{id}"

  @doc false
  def adapter_context(
        connection,
        %CreditSettlement{} = settlement,
        %PolicyVersion{} = policy,
        %Date{} = accounting_date
      ) do
    connection
    |> ERP.connection_context()
    |> Map.merge(%{
      journal_external_id: Integer.to_string(policy.journal_number),
      accounting_year_external_id: Integer.to_string(accounting_date.year),
      accounting_date: accounting_date,
      currency: settlement.currency
    })
  end

  defp enqueue_posting!(settlement, doc) do
    policy = Repo.get!(PolicyVersion, settlement.policy_version_id)

    operation =
      Operations.create!(%{
        team_id: settlement.team_id,
        type: "erp.post_customer_credit_settlement",
        actor_type: "system",
        actor_id: nil,
        target_type: "customer_credit_settlement",
        target_id: settlement.id,
        idempotency_key_hash:
          Canonical.hash(%{settlement_id: settlement.id, amount_minor: settlement.amount_minor}),
        metadata: %{
          "invoice_intent_id" => settlement.invoice_intent_id,
          "amount_minor" => settlement.amount_minor,
          "currency" => settlement.currency,
          "clearing_account" => policy.settlement_clearing_account_number
        }
      })

    erp_document =
      Repo.insert!(%ErpDocument{
        team_id: settlement.team_id,
        erp_connection_id: doc.erp_connection_id,
        invoice_intent_id: settlement.invoice_intent_id,
        document_type: "settlement_voucher",
        state: "pending",
        external_reference: external_reference(settlement)
      })

    operation_key = "post_customer_credit_settlement:#{settlement.id}"

    sync_operation =
      Repo.insert!(%SyncOperation{
        team_id: settlement.team_id,
        erp_document_id: erp_document.id,
        operation_id: operation.id,
        operation_type: "post_customer_credit_settlement",
        operation_key: operation_key,
        idempotency_key: Canonical.hash(%{operation_key: operation_key}),
        request_hash:
          Canonical.hash(%{
            settlement_id: settlement.id,
            amount_minor: settlement.amount_minor,
            currency: settlement.currency
          }),
        request_metadata: %{"external_reference" => external_reference(settlement)},
        state: "queued",
        created_at: DateTime.utc_now()
      })

    settlement
    |> Ecto.Changeset.change(operation_id: operation.id)
    |> Repo.update!()

    %{sync_operation_id: sync_operation.id}
    |> BillingCore.Credits.SettlementWorker.new()
    |> Oban.insert!()

    Audit.record!(:system, "credits.settlement.posting_requested",
      aggregate: {:customer_credit_settlement, settlement.id},
      team_id: settlement.team_id,
      payload: %{operation_id: operation.id, external_reference: external_reference(settlement)}
    )

    :ok
  end

  defp authorize(scope, roles) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, roles),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp ensure_presence(reference) do
    if String.trim(reference) == "", do: {:error, :invalid_reference}, else: :ok
  end
end
