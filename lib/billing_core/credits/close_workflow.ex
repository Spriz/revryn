defmodule BillingCore.Credits.CloseWorkflow do
  @moduledoc """
  Durable monthly customer-credit close commands (SPEC BC-US-163…165).

  This context is the sole coordinator for close persistence and ERP effects.
  Calculation and report rendering remain pure in `BillingCore.Credits.Close`;
  this module supplies team-scoped authorization, PostgreSQL serialization,
  immutable membership persistence, finance approval, and durable posting.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Credits, ERP, Operations, Outbox, Repo, Scope}

  alias BillingCore.Credits.Close, as: CloseKernel

  alias BillingCore.Credits.Close.{
    Approval,
    Calculation,
    Close,
    Evidence,
    Movement,
    PolicyVersion,
    TransactionMembership
  }

  alias BillingCore.Credits.{CreditAccount, CreditTransaction}
  alias BillingCore.Domain.{Canonical, Money}
  alias BillingCore.ERP.{Connection, ErpDocument, SyncOperation}

  alias BillingCore.ERP.Vouchers.{
    AttachmentEvidence,
    FinanceVoucher,
    FinanceVoucherLine,
    Voucher
  }

  @accepted_prior_states [:reconciled, :closed]
  @read_roles [:finance_operator, :billing_admin, :team_admin, :auditor, :integration_client]
  @write_roles [:finance_operator, :billing_admin]

  @doc """
  Freezes one deterministic close for a team, currency, and calendar month.

  Required attrs are `:currency`, `:period_start`, `:period_end_exclusive`,
  `:transaction_cutoff`, and `:policy_version_id`. The first close also
  requires the explicit `:bootstrap_opening_minor` (zero is valid).
  """
  @spec generate(Scope.t(), map() | keyword()) :: {:ok, Close.t()} | {:error, term()}
  def generate(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize_scope(scope, @write_roles),
         :ok <- validate_generation_attrs(attrs) do
      Repo.transaction(fn -> generate_locked!(scope, attrs) end)
    end
  end

  @doc "Approves the exact frozen report hash for ERP posting."
  @spec approve(Scope.t(), Close.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, Close.t()} | {:error, term()}
  def approve(%Scope{} = scope, close_or_id, opts \\ []) do
    with :ok <- authorize_scope(scope, @write_roles) do
      Repo.transaction(fn ->
        close = lock_close!(scope, close_id(close_or_id))
        ensure_state!(close, :ready)

        approval =
          Repo.insert!(%Approval{
            team_id: close.team_id,
            close_id: close.id,
            action: :approved,
            actor_type: actor_type(scope),
            actor_id: actor_id(scope),
            reason: Keyword.get(opts, :reason),
            close_hash: close.report_sha256,
            occurred_at: DateTime.utc_now()
          })

        close = transition_close!(close, :approve)

        Audit.record!(scope, "credits.close.approved",
          aggregate: {:customer_credit_close, close.id},
          payload: %{approval_id: approval.id, report_sha256: close.report_sha256}
        )

        Outbox.emit!("customer_credit_close.approved.v1",
          aggregate: {:customer_credit_close, close.id},
          team_id: close.team_id,
          correlation_id: scope.correlation_id,
          payload: %{approval_id: approval.id, report_sha256: close.report_sha256}
        )

        close
      end)
    end
  end

  @doc "Creates the durable, idempotent ERP posting operation for an approved close."
  @spec request_posting(Scope.t(), Close.t() | Ecto.UUID.t()) ::
          {:ok, Operations.Operation.t()} | {:error, term()}
  def request_posting(%Scope{} = scope, close_or_id) do
    with :ok <- authorize_scope(scope, @write_roles),
         {:ok, connection} <- ERP.get_connection(scope),
         :ok <- ensure_connection_active(connection) do
      Repo.transaction(fn ->
        request_posting_locked!(scope, close_id(close_or_id), connection)
      end)
    end
  end

  @doc "Accepts a fully reconciled close as the authoritative period close."
  @spec close_period(Scope.t(), Close.t() | Ecto.UUID.t()) ::
          {:ok, Close.t()} | {:error, term()}
  def close_period(%Scope{} = scope, close_or_id) do
    with :ok <- authorize_scope(scope, @write_roles) do
      Repo.transaction(fn ->
        close = lock_close!(scope, close_id(close_or_id))
        close = transition_close!(close, :close, %{closed_at: DateTime.utc_now()})

        Audit.record!(scope, "credits.close.closed",
          aggregate: {:customer_credit_close, close.id},
          payload: %{report_sha256: close.report_sha256}
        )

        Outbox.emit!("customer_credit_close.closed.v1",
          aggregate: {:customer_credit_close, close.id},
          team_id: close.team_id,
          correlation_id: scope.correlation_id,
          payload: %{report_sha256: close.report_sha256}
        )

        close
      end)
    end
  end

  @doc """
  Requests reversal of an accepted (`closed`) close (ADR-031, BC-US-165).

  The original moves to `reversal_pending` and a `reversal` close for the
  same period freezes with the mirrored bridge (opening/closing swapped, all
  deltas negated) and its own report evidence. The reversal close then runs
  the ordinary approve → post → reconcile flow; when its voucher reconciles,
  the original becomes `reversed` (terminal). Requires a `:reason`.
  """
  @spec request_reversal(Scope.t(), Close.t() | Ecto.UUID.t(), keyword()) ::
          {:ok, Close.t()} | {:error, term()}
  def request_reversal(%Scope{} = scope, close_or_id, opts \\ []) do
    reason = opts[:reason]

    with :ok <- authorize_scope(scope, @write_roles),
         :ok <- ensure_correction_reason(reason) do
      Repo.transaction(fn -> request_reversal_locked!(scope, close_id(close_or_id), reason) end)
    end
  end

  @doc """
  Freezes a `replacement` close for a `reversed` period under an explicitly
  chosen corrected policy version (ADR-031).

  The replacement reproduces the original's exact frozen figures by
  recomputing from the original's immutable transaction membership — the
  recomputed ledger snapshot hash must match — and inserts no membership
  rows of its own. It then runs the ordinary approve → post → reconcile →
  accept flow. Required attrs: `:policy_version_id`, `:reason`.
  """
  @spec generate_replacement(Scope.t(), Close.t() | Ecto.UUID.t(), map() | keyword()) ::
          {:ok, Close.t()} | {:error, term()}
  def generate_replacement(%Scope{} = scope, close_or_id, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize_scope(scope, @write_roles),
         :ok <- ensure_correction_reason(attrs[:reason]),
         policy_id when is_binary(policy_id) <-
           attrs[:policy_version_id] || {:error, :policy_version_required} do
      Repo.transaction(fn ->
        generate_replacement_locked!(scope, close_id(close_or_id), policy_id, attrs[:reason])
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns one stored immutable report file, team-scoped."
  @spec report(Scope.t(), Ecto.UUID.t(), atom()) ::
          {:ok, Evidence.t()} | {:error, :unauthorized | :not_found}
  def report(%Scope{} = scope, close_id, evidence_type) do
    with :ok <- authorize_scope(scope, @read_roles) do
      team_id = Scope.team_id!(scope)

      case Repo.one(
             from evidence in Evidence,
               where:
                 evidence.team_id == ^team_id and evidence.close_id == ^close_id and
                   evidence.evidence_type == ^evidence_type,
               order_by: [desc: evidence.created_at],
               limit: 1
           ) do
        nil -> {:error, :not_found}
        evidence -> {:ok, evidence}
      end
    end
  end

  @doc """
  Lists the team's closes, newest period first (capped at 100).
  Options: `:currency`, `:state`.
  """
  @spec list_closes(Scope.t(), keyword()) :: {:ok, [Close.t()]} | {:error, :unauthorized}
  def list_closes(%Scope{} = scope, opts \\ []) do
    with :ok <- authorize_scope(scope, @read_roles) do
      limit = opts |> Keyword.get(:limit, 100) |> min(100)

      query =
        from close in Close,
          where: close.team_id == ^Scope.team_id!(scope),
          order_by: [desc: close.period_start, desc: close.created_at],
          limit: ^limit

      query =
        case Keyword.get(opts, :currency) do
          nil -> query
          currency -> where(query, [close], close.currency == ^currency)
        end

      query =
        case Keyword.get(opts, :state) do
          nil -> query
          state -> where(query, [close], close.state == ^state)
        end

      {:ok, Repo.all(query)}
    end
  end

  @doc "Lists the team's close posting-policy versions, newest first."
  @spec list_policies(Scope.t()) :: {:ok, [PolicyVersion.t()]} | {:error, :unauthorized}
  def list_policies(%Scope{} = scope) do
    with :ok <- authorize_scope(scope, @read_roles) do
      {:ok,
       Repo.all(
         from policy in PolicyVersion,
           where: policy.team_id == ^Scope.team_id!(scope),
           order_by: [desc: policy.effective_from, desc: policy.version]
       )}
    end
  end

  @doc "Movement-type roll-up rows of one close, team-scoped."
  @spec list_movements(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [Movement.t()]} | {:error, :unauthorized}
  def list_movements(%Scope{} = scope, close_id) do
    with :ok <- authorize_scope(scope, @read_roles) do
      {:ok,
       Repo.all(
         from movement in Movement,
           where: movement.team_id == ^Scope.team_id!(scope) and movement.close_id == ^close_id,
           order_by: [asc: movement.movement_type]
       )}
    end
  end

  @doc """
  Metadata of one close's immutable evidence files (never the bytes) —
  type, hash, content type, and size, ordered by type.
  """
  @spec list_evidence_meta(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [map()]} | {:error, :unauthorized}
  def list_evidence_meta(%Scope{} = scope, close_id) do
    with :ok <- authorize_scope(scope, @read_roles) do
      {:ok,
       Repo.all(
         from evidence in Evidence,
           where: evidence.team_id == ^Scope.team_id!(scope) and evidence.close_id == ^close_id,
           order_by: [asc: evidence.evidence_type, desc: evidence.created_at],
           select: %{
             evidence_type: evidence.evidence_type,
             sha256: evidence.sha256,
             content_type: evidence.content_type,
             byte_size: fragment("octet_length(?)", evidence.bytes),
             created_at: evidence.created_at
           }
       )
       |> Enum.uniq_by(& &1.evidence_type)}
    end
  end

  @doc "Correction closes referencing this close (ADR-031), oldest first."
  @spec list_corrections(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [Close.t()]} | {:error, :unauthorized}
  def list_corrections(%Scope{} = scope, close_id) do
    with :ok <- authorize_scope(scope, @read_roles) do
      {:ok,
       Repo.all(
         from close in Close,
           where:
             close.team_id == ^Scope.team_id!(scope) and
               close.reversal_of_close_id == ^close_id,
           order_by: [asc: close.created_at]
       )}
    end
  end

  @doc "The latest approval record of a close, or nil."
  @spec latest_approval(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Approval.t() | nil} | {:error, :unauthorized}
  def latest_approval(%Scope{} = scope, close_id) do
    with :ok <- authorize_scope(scope, @read_roles) do
      {:ok,
       Repo.one(
         from approval in Approval,
           where: approval.team_id == ^Scope.team_id!(scope) and approval.close_id == ^close_id,
           order_by: [desc: approval.occurred_at],
           limit: 1
       )}
    end
  end

  @doc """
  Durable posting evidence of a close: its operation, ERP sync operation,
  and mirrored ERP document, any of which may be nil before posting or for
  zero-delta local reconciliation.
  """
  @spec posting_status(Scope.t(), Close.t()) ::
          {:ok,
           %{
             operation: Operations.Operation.t() | nil,
             sync_operation: SyncOperation.t() | nil,
             document: ErpDocument.t() | nil
           }}
          | {:error, :unauthorized}
  def posting_status(%Scope{} = scope, %Close{} = close) do
    with :ok <- authorize_scope(scope, @read_roles),
         :ok <-
           if(Scope.team_id!(scope) == close.team_id, do: :ok, else: {:error, :unauthorized}) do
      team_id = Scope.team_id!(scope)

      operation =
        close.operation_id &&
          Repo.one(
            from operation in Operations.Operation,
              where: operation.id == ^close.operation_id and operation.team_id == ^team_id
          )

      sync_operation =
        operation &&
          Repo.one(
            from sync_op in SyncOperation,
              where: sync_op.operation_id == ^operation.id and sync_op.team_id == ^team_id,
              order_by: [desc: sync_op.created_at],
              limit: 1
          )

      document =
        Repo.one(
          from document in ErpDocument,
            where:
              document.customer_credit_close_id == ^close.id and document.team_id == ^team_id,
            order_by: [desc: document.created_at],
            limit: 1
        )

      {:ok, %{operation: operation, sync_operation: sync_operation, document: document}}
    end
  end

  @doc false
  @spec build_finance_voucher(Close.t(), PolicyVersion.t(), [Movement.t()]) ::
          {:ok, FinanceVoucher.t()} | {:error, term()}
  def build_finance_voucher(%Close{} = close, %PolicyVersion{} = policy, movements) do
    reference = external_reference(close)

    liability_line = %FinanceVoucherLine{
      line_key: "customer-credit-liability",
      account_external_id: to_string(policy.liability_account_number),
      amount: Money.new!(close.currency, close.economic_liability_line_minor),
      role: :customer_credit_liability,
      description: "Customer-credit liability close"
    }

    with {:ok, balancing_lines} <- balancing_lines(close, policy, movements) do
      voucher = %FinanceVoucher{
        external_reference: reference,
        accounting_date: Date.add(close.period_end_exclusive, -1),
        accounting_year_external_id: Integer.to_string(close.period_start.year),
        journal_external_id: Integer.to_string(policy.journal_number),
        currency: close.currency,
        lines: [liability_line | balancing_lines],
        vat_neutral: policy.vat_neutral
      }

      case FinanceVoucher.validate(voucher) do
        :ok -> {:ok, voucher}
        {:error, errors} -> {:error, {:invalid_finance_voucher, errors}}
      end
    end
  end

  @doc false
  def adapter_context(%Connection{} = connection, %Close{} = close, %PolicyVersion{} = policy) do
    connection
    |> ERP.connection_context()
    |> Map.merge(%{
      journal_external_id: Integer.to_string(policy.journal_number),
      accounting_year_external_id: Integer.to_string(close.period_start.year),
      accounting_date: Date.add(close.period_end_exclusive, -1),
      currency: close.currency,
      credit_liability_account_external_id: Integer.to_string(policy.liability_account_number)
    })
  end

  @doc false
  def report_attachment!(close_id) do
    evidence =
      Repo.one!(
        from evidence in Evidence,
          where: evidence.close_id == ^close_id and evidence.evidence_type == :pdf_summary,
          order_by: [desc: evidence.created_at],
          limit: 1
      )

    %AttachmentEvidence{
      filename: "revryn-credit-close-#{close_id}.pdf",
      content_type: evidence.content_type,
      sha256: evidence.sha256,
      byte_size: byte_size(evidence.bytes),
      content: evidence.bytes
    }
  end

  @doc false
  @spec voucher_matches?(FinanceVoucher.t(), Voucher.t()) :: boolean()
  def voucher_matches?(%FinanceVoucher{} = expected, %Voucher{} = actual) do
    actual.external_reference == expected.external_reference and
      actual.accounting_date == expected.accounting_date and
      actual.accounting_year_external_id == expected.accounting_year_external_id and
      actual.journal_external_id == expected.journal_external_id and
      actual.currency == expected.currency and
      line_signature(actual.lines) == line_signature(expected.lines)
  end

  @doc false
  def external_reference(%Close{} = close) do
    month = close.period_start |> Date.to_iso8601() |> String.slice(0, 7)
    "REVRYN:CREDIT-CLOSE:#{close.id}:#{month}:#{close.currency}"
  end

  @doc false
  def transition_close!(%Close{} = close, event, attrs \\ %{}) do
    case CloseKernel.transition(close, event) do
      {:ok, state} ->
        close
        |> Ecto.Changeset.change(Map.put(attrs, :state, state))
        |> Repo.update!()

      {:error, error} ->
        Repo.rollback({:illegal_close_transition, error})
    end
  end

  defp generate_locked!(scope, attrs) do
    team_id = Scope.team_id!(scope)
    currency = attrs.currency
    period_start = attrs.period_start
    period_end = attrs.period_end_exclusive
    cutoff = attrs.transaction_cutoff

    close_lock!(team_id, currency, period_start)

    if existing =
         Repo.one(
           from close in Close,
             where:
               close.team_id == ^team_id and close.currency == ^currency and
                 close.period_start == ^period_start and
                 close.period_end_exclusive == ^period_end,
             limit: 1
         ) do
      Repo.rollback({:already_exists, existing.id})
    end

    policy = policy_for_close!(team_id, attrs.policy_version_id, period_start)

    {opening, previous, previous_cutoff} =
      opening_balance!(team_id, currency, period_start, attrs)

    accounts = lock_and_reconcile_accounts!(team_id, currency)
    transactions = unmatched_transactions(team_id, currency, period_end, cutoff)

    approved_prior_ids =
      attrs |> Map.get(:approved_prior_period_transaction_ids, []) |> List.wrap()

    ensure_no_missed_prior_transactions!(
      transactions,
      period_start,
      previous_cutoff,
      approved_prior_ids
    )

    effect =
      Enum.reduce(transactions, 0, fn transaction, total ->
        case Calculation.liability_effect(Map.from_struct(transaction)) do
          {:ok, {_movement, signed_effect}} -> total + signed_effect
          {:error, reason} -> Repo.rollback({:invalid_credit_transaction, transaction.id, reason})
        end
      end)

    closing = opening + effect

    if closing < 0 do
      Repo.rollback({:negative_closing_balance, closing})
    end

    verify_current_projection_when_safe!(
      team_id,
      currency,
      accounts,
      cutoff,
      closing
    )

    calculation_input = %{
      opening_minor: opening,
      closing_minor: closing,
      currency: currency,
      period_start: period_start,
      previous_transaction_cutoff: previous_cutoff,
      approved_prior_period_transaction_ids: approved_prior_ids,
      transactions: transactions
    }

    snapshot =
      case CloseKernel.calculate(calculation_input) do
        {:ok, snapshot} -> snapshot
        {:error, reason} -> Repo.rollback(reason)
      end

    close_id = Ecto.UUID.generate()

    report_input = %{
      id: close_id,
      team_id: team_id,
      currency: currency,
      period_start: period_start,
      period_end_exclusive: period_end,
      transaction_cutoff: cutoff,
      policy_version_id: policy.id
    }

    bundle = CloseKernel.build_report(report_input, snapshot)

    close =
      Repo.insert!(%Close{
        id: close_id,
        team_id: team_id,
        currency: currency,
        period_start: period_start,
        period_end_exclusive: period_end,
        transaction_cutoff: cutoff,
        policy_version_id: policy.id,
        state: :ready,
        opening_minor: snapshot.opening_minor,
        closing_minor: snapshot.closing_minor,
        net_change_minor: snapshot.net_change_minor,
        economic_liability_line_minor: snapshot.economic_liability_line_minor,
        ledger_transaction_count: snapshot.ledger_transaction_count,
        ledger_snapshot_hash: snapshot.ledger_snapshot_hash,
        report_sha256: bundle.report_sha256,
        report_storage_key: "db://customer-credit-closes/#{close_id}/manifest",
        previous_close_id: previous && previous.id
      })

    persist_movements!(close, snapshot.movements)
    persist_memberships!(close, snapshot.memberships)
    {:ok, 4} = CloseKernel.persist_report(scope, close, bundle)

    Audit.record!(scope, "credits.close.calculated",
      aggregate: {:customer_credit_close, close.id},
      payload:
        close
        |> close_event_payload()
        |> Map.put(:approved_prior_period_transaction_ids, approved_prior_ids)
    )

    Outbox.emit!("customer_credit_close.calculated.v1",
      aggregate: {:customer_credit_close, close.id},
      team_id: close.team_id,
      correlation_id: scope.correlation_id,
      payload: close_event_payload(close)
    )

    :telemetry.execute(
      [:billing_core, :customer_credit_close, :calculated],
      %{count: 1, ledger_transaction_count: close.ledger_transaction_count},
      %{currency: close.currency, result: :ready}
    )

    Repo.preload(close, [:policy_version, :movements, :transaction_memberships])
  end

  defp request_reversal_locked!(scope, close_id, reason) do
    original = lock_close!(scope, close_id)
    close_lock!(original.team_id, original.currency, original.period_start)
    ensure_state!(original, :closed)

    if original.close_kind == :reversal do
      Repo.rollback(:cannot_reverse_a_reversal)
    end

    original = transition_close!(original, :request_reversal)

    snapshot = %{
      opening_minor: original.closing_minor,
      closing_minor: original.opening_minor,
      net_change_minor: -original.net_change_minor,
      economic_liability_line_minor: -original.economic_liability_line_minor,
      ledger_transaction_count: 0,
      ledger_snapshot_hash: original.ledger_snapshot_hash,
      memberships: [],
      movements: [],
      transactions: []
    }

    reversal =
      insert_correction_close!(
        scope,
        original,
        :reversal,
        original.policy_version_id,
        snapshot,
        reason
      )

    Audit.record!(scope, "credits.close.reversal_requested",
      aggregate: {:customer_credit_close, original.id},
      payload: %{reversal_close_id: reversal.id, reason: reason}
    )

    Outbox.emit!("customer_credit_close.reversal_requested.v1",
      aggregate: {:customer_credit_close, original.id},
      team_id: original.team_id,
      correlation_id: scope.correlation_id,
      payload: %{reversal_close_id: reversal.id, reason: reason}
    )

    reversal
  end

  defp generate_replacement_locked!(scope, close_id, policy_version_id, reason) do
    original = lock_close!(scope, close_id)
    close_lock!(original.team_id, original.currency, original.period_start)
    ensure_state!(original, :reversed)

    existing_replacement =
      Repo.one(
        from close in Close,
          where:
            close.team_id == ^original.team_id and close.currency == ^original.currency and
              close.period_start == ^original.period_start and
              close.close_kind != :reversal and
              close.state not in [:superseded, :reversed],
          limit: 1
      )

    if existing_replacement, do: Repo.rollback({:already_exists, existing_replacement.id})

    policy = policy_for_close!(original.team_id, policy_version_id, original.period_start)

    transactions =
      Repo.all(
        from transaction in CreditTransaction,
          join: membership in TransactionMembership,
          on: membership.transaction_id == transaction.id,
          where: membership.close_id == ^original.id,
          order_by: [asc: membership.ledger_ordinal]
      )

    snapshot =
      case CloseKernel.calculate(%{
             opening_minor: original.opening_minor,
             closing_minor: original.closing_minor,
             currency: original.currency,
             period_start: original.period_start,
             previous_transaction_cutoff: nil,
             transactions: transactions
           }) do
        {:ok, snapshot} -> snapshot
        {:error, calc_reason} -> Repo.rollback(calc_reason)
      end

    if snapshot.ledger_snapshot_hash != original.ledger_snapshot_hash do
      Repo.rollback(:ledger_snapshot_mismatch)
    end

    replacement =
      insert_correction_close!(scope, original, :replacement, policy.id, snapshot, reason)

    persist_movements!(replacement, snapshot.movements)

    Audit.record!(scope, "credits.close.replacement_generated",
      aggregate: {:customer_credit_close, replacement.id},
      payload: %{reversed_close_id: original.id, reason: reason}
    )

    Outbox.emit!("customer_credit_close.replacement_generated.v1",
      aggregate: {:customer_credit_close, replacement.id},
      team_id: replacement.team_id,
      correlation_id: scope.correlation_id,
      payload: %{reversed_close_id: original.id, reason: reason}
    )

    replacement
  end

  # A correction close is a full close row (ADR-031): same period, its own
  # report evidence and report hash, linked to the close it corrects, with
  # zero membership rows — the frozen membership stays on the original.
  defp insert_correction_close!(scope, original, kind, policy_version_id, snapshot, reason) do
    correction_id = Ecto.UUID.generate()

    report_input = %{
      id: correction_id,
      team_id: original.team_id,
      currency: original.currency,
      period_start: original.period_start,
      period_end_exclusive: original.period_end_exclusive,
      transaction_cutoff: original.transaction_cutoff,
      policy_version_id: policy_version_id,
      close_kind: kind,
      reversal_of_close_id: original.id,
      correction_reason: reason
    }

    bundle = CloseKernel.build_report(report_input, snapshot)

    close =
      Repo.insert!(%Close{
        id: correction_id,
        team_id: original.team_id,
        currency: original.currency,
        period_start: original.period_start,
        period_end_exclusive: original.period_end_exclusive,
        transaction_cutoff: original.transaction_cutoff,
        policy_version_id: policy_version_id,
        close_kind: kind,
        reversal_of_close_id: original.id,
        previous_close_id: original.previous_close_id,
        state: :ready,
        opening_minor: snapshot.opening_minor,
        closing_minor: snapshot.closing_minor,
        net_change_minor: snapshot.net_change_minor,
        economic_liability_line_minor: snapshot.economic_liability_line_minor,
        ledger_transaction_count: snapshot.ledger_transaction_count,
        ledger_snapshot_hash: snapshot.ledger_snapshot_hash,
        report_sha256: bundle.report_sha256,
        report_storage_key: "db://customer-credit-closes/#{correction_id}/manifest"
      })

    {:ok, 4} = CloseKernel.persist_report(scope, close, bundle)
    close
  end

  defp ensure_correction_reason(reason) when is_binary(reason) and byte_size(reason) > 0, do: :ok
  defp ensure_correction_reason(_reason), do: {:error, :correction_reason_required}

  # ADR-031: a locally reconciled zero-delta reversal close still terminally
  # reverses its original.
  defp finalize_zero_delta_reversal!(scope, %Close{
         close_kind: :reversal,
         reversal_of_close_id: original_id
       })
       when is_binary(original_id) do
    original = Repo.get!(Close, original_id)

    if original.state == :reversal_pending do
      reversed = transition_close!(original, :reversal_reconciled)

      Audit.record!(scope, "credits.close.reversed",
        aggregate: {:customer_credit_close, reversed.id},
        payload: %{report_sha256: reversed.report_sha256}
      )

      Outbox.emit!("customer_credit_close.reversed.v1",
        aggregate: {:customer_credit_close, reversed.id},
        team_id: reversed.team_id,
        correlation_id: scope.correlation_id,
        payload: %{report_sha256: reversed.report_sha256}
      )
    end

    :ok
  end

  defp finalize_zero_delta_reversal!(_scope, _close), do: :ok

  defp request_posting_locked!(scope, close_id, connection) do
    close = lock_close!(scope, close_id)
    ensure_state!(close, :approved)
    ensure_current_approval!(close)

    close = Repo.preload(close, [:policy_version, :movements])
    {:ok, voucher} = build_finance_voucher(close, close.policy_version, close.movements)

    operation = create_post_operation!(scope, close)

    if close.net_change_minor == 0 and not close.policy_version.post_zero_delta do
      complete_zero_delta!(scope, close, operation)
    else
      enqueue_posting!(scope, close, connection, operation, voucher)
    end
  end

  defp complete_zero_delta!(scope, close, operation) do
    operation = Operations.transition!(operation, :claim)
    close = transition_close!(close, :start_posting, %{operation_id: operation.id})
    close = transition_close!(close, :posting_succeeded)
    close = transition_close!(close, :reconcile)
    operation = Operations.transition!(operation, :succeed)

    finalize_zero_delta_reversal!(scope, close)

    Audit.record!(scope, "credits.close.zero_delta_reconciled",
      aggregate: {:customer_credit_close, close.id},
      payload: %{operation_id: operation.id, report_sha256: close.report_sha256}
    )

    emit_posting_events!(close, operation.id, nil)
    operation
  end

  defp enqueue_posting!(scope, close, connection, operation, voucher) do
    erp_document =
      Repo.insert!(%ErpDocument{
        team_id: close.team_id,
        erp_connection_id: connection.id,
        customer_credit_close_id: close.id,
        document_type: "finance_voucher",
        state: "pending",
        external_reference: voucher.external_reference
      })

    operation_key = "post_customer_credit_close:#{close.id}:#{close.report_sha256}"

    sync_operation =
      Repo.insert!(%SyncOperation{
        team_id: close.team_id,
        erp_document_id: erp_document.id,
        operation_id: operation.id,
        operation_type: "post_customer_credit_close",
        operation_key: operation_key,
        idempotency_key: Canonical.hash(%{operation_key: operation_key}),
        request_hash: close.report_sha256,
        request_metadata: %{
          "external_reference" => voucher.external_reference,
          "attachment_sha256" => report_attachment!(close.id).sha256
        },
        state: "queued",
        created_at: DateTime.utc_now()
      })

    close =
      transition_close!(close, :start_posting, %{
        operation_id: operation.id,
        erp_document_id: erp_document.id
      })

    Audit.record!(scope, "credits.close.post_requested",
      aggregate: {:customer_credit_close, close.id},
      payload: %{operation_id: operation.id, external_reference: voucher.external_reference}
    )

    Outbox.emit!("customer_credit_close.post_requested.v1",
      aggregate: {:customer_credit_close, close.id},
      team_id: close.team_id,
      correlation_id: scope.correlation_id,
      payload: %{operation_id: operation.id, external_reference: voucher.external_reference}
    )

    %{sync_operation_id: sync_operation.id}
    |> BillingCore.Credits.CloseWorker.new()
    |> Oban.insert!()

    operation
  end

  defp create_post_operation!(scope, close) do
    Operations.create!(%{
      team_id: close.team_id,
      organization_id: scope.organization && scope.organization.id,
      type: "erp.post_customer_credit_close",
      actor_type: actor_type(scope),
      actor_id: actor_id(scope),
      target_type: "customer_credit_close",
      target_id: close.id,
      correlation_id: scope.correlation_id,
      idempotency_key_hash: Canonical.hash(%{close_id: close.id, hash: close.report_sha256}),
      metadata: %{"report_sha256" => close.report_sha256}
    })
  end

  defp policy_for_close!(team_id, policy_version_id, period_start) do
    case Repo.one(
           from policy in PolicyVersion,
             where:
               policy.id == ^policy_version_id and policy.team_id == ^team_id and
                 policy.effective_from <= ^period_start,
             lock: "FOR SHARE"
         ) do
      nil -> Repo.rollback(:close_policy_not_effective)
      policy -> policy
    end
  end

  # Continuity resolves the newest regular/replacement close of the
  # preceding period; reversal closes are aggregate GL compensations and
  # never part of the opening chain (ADR-031). A reversed period without an
  # accepted replacement blocks generation explicitly.
  defp opening_balance!(team_id, currency, period_start, attrs) do
    previous =
      Repo.one(
        from close in Close,
          where:
            close.team_id == ^team_id and close.currency == ^currency and
              close.period_start < ^period_start and close.close_kind != :reversal,
          order_by: [desc: close.period_start, desc: close.created_at],
          limit: 1,
          lock: "FOR UPDATE"
      )

    case previous do
      nil ->
        if Map.has_key?(attrs, :bootstrap_opening_minor) and
             is_integer(attrs.bootstrap_opening_minor) and attrs.bootstrap_opening_minor >= 0 do
          {attrs.bootstrap_opening_minor, nil, nil}
        else
          Repo.rollback(:bootstrap_opening_required)
        end

      %Close{state: :reversed} = previous ->
        Repo.rollback({:previous_close_reversed, previous.id})

      %Close{state: state, period_end_exclusive: ^period_start} = previous
      when state in @accepted_prior_states ->
        {previous.closing_minor, previous, previous.transaction_cutoff}

      %Close{state: state} ->
        Repo.rollback({:previous_close_not_accepted, state})
    end
  end

  defp lock_and_reconcile_accounts!(team_id, currency) do
    accounts =
      Repo.all(
        from account in CreditAccount,
          where: account.team_id == ^team_id and account.currency == ^currency,
          order_by: [asc: account.id],
          lock: "FOR UPDATE"
      )

    Enum.each(accounts, &Credits.reconcile_account!(&1.id))
    accounts
  end

  defp unmatched_transactions(team_id, currency, period_end, cutoff) do
    Repo.all(
      from transaction in CreditTransaction,
        left_join: membership in TransactionMembership,
        on: membership.transaction_id == transaction.id,
        where:
          transaction.team_id == ^team_id and transaction.currency == ^currency and
            transaction.accounting_effective_on < ^period_end and
            transaction.occurred_at <= ^cutoff and
            is_nil(membership.transaction_id),
        order_by: [
          asc: transaction.accounting_effective_on,
          asc: transaction.occurred_at,
          asc: transaction.id
        ]
    )
  end

  defp ensure_no_missed_prior_transactions!(_transactions, _period_start, nil, _approved),
    do: :ok

  # A transaction the prior close should have seen (occurred at or before its
  # cutoff, effective inside a closed period) blocks generation unless it is
  # explicitly approved as a current-period prior-period adjustment
  # (BC-US-165: never backdated silently).
  defp ensure_no_missed_prior_transactions!(transactions, period_start, previous_cutoff, approved) do
    missed =
      Enum.find(transactions, fn transaction ->
        Date.before?(transaction.accounting_effective_on, period_start) and
          DateTime.compare(transaction.occurred_at, previous_cutoff) != :gt and
          transaction.id not in approved
      end)

    if missed, do: Repo.rollback({:missed_prior_transaction, missed.id}), else: :ok
  end

  defp verify_current_projection_when_safe!(team_id, currency, accounts, cutoff, closing) do
    later_count =
      Repo.one(
        from transaction in CreditTransaction,
          where:
            transaction.team_id == ^team_id and transaction.currency == ^currency and
              transaction.occurred_at > ^cutoff,
          select: count(transaction.id)
      )

    if later_count == 0 do
      projected = Enum.sum(Enum.map(accounts, &(&1.available_minor + &1.reserved_minor)))

      if projected != closing,
        do: Repo.rollback({:projection_at_cutoff_mismatch, projected, closing})
    end
  end

  defp persist_movements!(close, movements) do
    now = DateTime.utc_now()

    rows =
      Enum.map(movements, fn movement ->
        movement
        |> Map.take([
          :movement_type,
          :amount_minor,
          :liability_effect_minor,
          :transaction_count,
          :contra_account_number
        ])
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          team_id: close.team_id,
          close_id: close.id,
          created_at: now
        })
      end)

    Repo.insert_all(Movement, rows)
  end

  defp persist_memberships!(close, memberships) do
    now = DateTime.utc_now()

    rows =
      Enum.map(memberships, fn membership ->
        Map.merge(membership, %{close_id: close.id, created_at: now})
      end)

    Repo.insert_all(TransactionMembership, rows)
  end

  defp balancing_lines(close, %{posting_mode: :single_offset} = policy, _movements) do
    if is_integer(policy.default_offset_account_number) do
      {:ok,
       [
         %FinanceVoucherLine{
           line_key: "aggregate-offset",
           account_external_id: to_string(policy.default_offset_account_number),
           amount: Money.new!(close.currency, close.net_change_minor),
           role: :balancing,
           description: "Aggregate customer-credit movement"
         }
       ]}
    else
      {:error, :missing_default_offset_account}
    end
  end

  defp balancing_lines(close, %{posting_mode: :movement_class} = policy, movements) do
    movements
    |> Enum.reject(&(&1.liability_effect_minor == 0))
    |> Enum.reduce_while({:ok, %{}}, fn movement, {:ok, grouped} ->
      key = Atom.to_string(movement.movement_type)
      account = policy.movement_account_map[key]

      if account do
        {:cont,
         {:ok,
          Map.update(
            grouped,
            to_string(account),
            movement.liability_effect_minor,
            &(&1 + movement.liability_effect_minor)
          )}}
      else
        {:halt, {:error, {:missing_movement_account, movement.movement_type}}}
      end
    end)
    |> then(fn
      {:error, reason} ->
        {:error, reason}

      {:ok, grouped} ->
        lines =
          grouped
          |> Enum.reject(fn {_account, amount} -> amount == 0 end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.with_index()
          |> Enum.map(fn {{account, amount}, index} ->
            %FinanceVoucherLine{
              line_key: "movement-offset-#{index + 1}",
              account_external_id: account,
              amount: Money.new!(close.currency, amount),
              role: :balancing,
              description: "Aggregate customer-credit movement"
            }
          end)

        {:ok, lines}
    end)
  end

  defp balancing_lines(_close, _policy, _movements), do: {:error, :unsupported_posting_mode}

  defp line_signature(lines) do
    lines
    |> Enum.map(fn line ->
      {line.account_external_id, line.amount.currency, line.amount.minor_units}
    end)
    |> Enum.sort()
  end

  defp lock_close!(scope, close_id) do
    team_id = Scope.team_id!(scope)

    Repo.one(
      from close in Close,
        where: close.id == ^close_id and close.team_id == ^team_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp close_lock!(team_id, currency, period_start) do
    key = "customer-credit-close:#{team_id}:#{currency}:#{Date.to_iso8601(period_start)}"
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
  end

  defp ensure_current_approval!(close) do
    approval =
      Repo.one(
        from approval in Approval,
          where: approval.close_id == ^close.id and approval.action == :approved,
          order_by: [desc: approval.occurred_at],
          limit: 1
      )

    if is_nil(approval) or approval.close_hash != close.report_sha256 do
      Repo.rollback(:approval_missing_or_stale)
    end
  end

  defp ensure_state!(%Close{state: state}, state), do: :ok

  defp ensure_state!(%Close{state: state}, expected),
    do: Repo.rollback({:invalid_close_state, state, expected})

  defp validate_generation_attrs(attrs) do
    with currency when is_binary(currency) <- attrs[:currency],
         true <- Money.valid_currency?(currency),
         %Date{} = period_start <- attrs[:period_start],
         %Date{} = period_end <- attrs[:period_end_exclusive],
         %DateTime{} <- attrs[:transaction_cutoff],
         policy_id when is_binary(policy_id) <- attrs[:policy_version_id],
         true <- calendar_month?(period_start, period_end) do
      :ok
    else
      _ -> {:error, :invalid_close_attributes}
    end
  end

  defp calendar_month?(%Date{day: 1} = start_date, end_date) do
    Date.add(Date.end_of_month(start_date), 1) == end_date
  end

  defp calendar_month?(_start_date, _end_date), do: false

  defp ensure_connection_active(%Connection{status: "active"}), do: :ok

  defp ensure_connection_active(%Connection{status: status}),
    do: {:error, {:connection_not_usable, status}}

  defp authorize_scope(%Scope{} = scope, roles) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, roles),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp close_id(%Close{id: id}), do: id
  defp close_id(id) when is_binary(id), do: id

  defp actor_type(%Scope{principal_type: :service}), do: "service"
  defp actor_type(%Scope{}), do: "user"

  defp actor_id(%Scope{principal_type: :user, user: %{id: id}}), do: to_string(id)

  defp actor_id(%Scope{principal_type: :service, service_credential: %{id: id}}),
    do: to_string(id)

  defp actor_id(_), do: nil

  defp close_event_payload(close) do
    %{
      currency: close.currency,
      period_start: close.period_start,
      period_end_exclusive: close.period_end_exclusive,
      opening_minor: close.opening_minor,
      closing_minor: close.closing_minor,
      net_change_minor: close.net_change_minor,
      economic_liability_line_minor: close.economic_liability_line_minor,
      ledger_transaction_count: close.ledger_transaction_count,
      ledger_snapshot_hash: close.ledger_snapshot_hash,
      report_sha256: close.report_sha256
    }
  end

  defp emit_posting_events!(close, operation_id, voucher_number) do
    common = [
      aggregate: {:customer_credit_close, close.id},
      team_id: close.team_id,
      causation_id: operation_id,
      payload: %{
        operation_id: operation_id,
        external_voucher_number: voucher_number,
        report_sha256: close.report_sha256
      }
    ]

    Outbox.emit!("customer_credit_close.posted.v1", common)
    Outbox.emit!("customer_credit_close.reconciled.v1", common)
  end
end
