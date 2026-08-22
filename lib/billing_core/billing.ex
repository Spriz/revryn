defmodule BillingCore.Billing do
  @moduledoc """
  Billing runs, immutable invoice intent, and the intent lifecycle
  (SPEC §13.3, §11.2, BC-US-066/068/069/100, INV-003/004/013).

  Freezing produces the immutable snapshot + SHA-256 hash before any external
  effect (ADR-015). All mutable workflow state lives in
  `invoice_intent_lifecycle`; intents and lines are database-protected
  against update/delete.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Outbox, Repo, Scope}

  alias BillingCore.Billing.{
    BillingRun,
    Charge,
    IntentLifecycle,
    IntentMachine,
    InvoiceChain,
    InvoiceIntent,
    InvoiceLine
  }

  alias BillingCore.Domain.{Canonical, Money}

  @engine_version "1"

  @doc "Rating/normalization engine version stamped on runs and traces."
  def engine_version, do: @engine_version

  ## Billing runs

  @doc "Opens a billing run; duplicate `run_key` returns the existing run (SPEC §18.1)."
  @spec open_run(Scope.t(), map()) ::
          {:ok, BillingRun.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def open_run(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, [:billing_admin, :team_admin, :finance_operator]) do
      team_id = Scope.team_id!(scope)

      run = %BillingRun{
        team_id: team_id,
        run_key: Map.fetch!(attrs, :run_key),
        invoice_date: Map.fetch!(attrs, :invoice_date),
        usage_cutoff: Map.fetch!(attrs, :usage_cutoff),
        settings_version: Map.get(attrs, :settings_version, 1),
        engine_version: @engine_version,
        status: "open",
        started_at: DateTime.utc_now()
      }

      case Repo.get_by(BillingRun, team_id: team_id, run_key: run.run_key) do
        %BillingRun{} = existing ->
          {:ok, existing}

        nil ->
          Repo.transaction(fn ->
            inserted = Repo.insert!(run)
            Audit.record!(scope, "billing.run.opened", aggregate: {:billing_run, inserted.id})

            Outbox.emit!("billing_run.opened.v1",
              aggregate: {:billing_run, inserted.id},
              team_id: team_id,
              correlation_id: scope.correlation_id,
              payload: %{run_key: inserted.run_key, invoice_date: inserted.invoice_date}
            )

            inserted
          end)
          |> case do
            {:ok, inserted} -> {:ok, inserted}
          end
      end
    end
  rescue
    e in Ecto.ConstraintError ->
      # Concurrent creation with the same run key (SPEC §18.1): the database
      # unique constraint wins; return the existing run.
      if e.constraint =~ "billing_runs_team_id_run_key" do
        {:ok,
         Repo.get_by!(BillingRun,
           team_id: Scope.team_id!(scope),
           run_key: Map.fetch!(attrs, :run_key)
         )}
      else
        reraise(e, __STACKTRACE__)
      end
  end

  @doc "Closes a run; refuses while unresolved intents exist (BC-US-116)."
  @spec close_run(Scope.t(), BillingRun.t()) ::
          {:ok, BillingRun.t()} | {:error, :unauthorized | :unresolved_intents}
  def close_run(%Scope{} = scope, %BillingRun{} = run) do
    with :ok <- authorize(scope, [:finance_operator, :team_admin]),
         :ok <- ensure_team(scope, run.team_id) do
      unresolved =
        Repo.exists?(
          from l in IntentLifecycle,
            join: i in InvoiceIntent,
            on: i.id == l.invoice_intent_id,
            where:
              i.billing_run_id == ^run.id and
                l.current_state in ["frozen", "sync_pending", "sync_error", "booking_pending"]
        )

      if unresolved do
        {:error, :unresolved_intents}
      else
        {:ok, run} =
          Repo.transaction(fn ->
            run
            |> Ecto.Changeset.change(status: "closed", closed_at: DateTime.utc_now())
            |> Repo.update!()
            |> tap(fn r ->
              Audit.record!(scope, "billing.run.closed", aggregate: {:billing_run, r.id})
            end)
          end)

        {:ok, run}
      end
    end
  end

  @read_roles [:finance_operator, :billing_admin, :team_admin, :auditor]

  @doc "Lists the team's billing runs, newest first (capped at 100)."
  @spec list_runs(Scope.t(), keyword()) ::
          {:ok, [BillingRun.t()]} | {:error, :unauthorized}
  def list_runs(%Scope{} = scope, opts \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      limit = opts |> Keyword.get(:limit, 100) |> min(100)

      {:ok,
       Repo.all(
         from r in BillingRun,
           where: r.team_id == ^Scope.team_id!(scope),
           order_by: [desc: r.invoice_date, desc: r.created_at],
           limit: ^limit
       )}
    end
  end

  @doc "Fetches a billing run of the scope's team."
  @spec get_run(Scope.t(), Ecto.UUID.t()) ::
          {:ok, BillingRun.t()} | {:error, :unauthorized | :not_found}
  def get_run(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(BillingRun, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        run -> {:ok, run}
      end
    end
  end

  @doc "Number of the team's open billing runs."
  @spec count_open_runs(Scope.t()) :: {:ok, non_neg_integer()} | {:error, :unauthorized}
  def count_open_runs(%Scope{} = scope) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.aggregate(
         from(r in BillingRun,
           where: r.team_id == ^Scope.team_id!(scope) and r.status == "open"
         ),
         :count
       )}
    end
  end

  @doc """
  The intents of a billing run with their current lifecycle state, ordered by
  creation (BC-US-115). Returns `[%{intent: intent, state: state}]`.
  """
  @spec list_run_intents(Scope.t(), BillingRun.t()) ::
          {:ok, [%{intent: InvoiceIntent.t(), state: String.t()}]}
          | {:error, :unauthorized}
  def list_run_intents(%Scope{} = scope, %BillingRun{} = run) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- ensure_team(scope, run.team_id) do
      rows =
        Repo.all(
          from i in InvoiceIntent,
            join: l in IntentLifecycle,
            on: l.invoice_intent_id == i.id,
            where: i.billing_run_id == ^run.id and i.team_id == ^run.team_id,
            order_by: [asc: i.created_at],
            select: {i, l.current_state}
        )

      {:ok, Enum.map(rows, fn {intent, state} -> %{intent: intent, state: state} end)}
    end
  end

  @doc """
  Lists the team's invoice intents with lifecycle state, newest first
  (capped at 100). Options: `:customer_id`, `:state`.
  """
  @spec list_intents(Scope.t(), keyword()) ::
          {:ok, [%{intent: InvoiceIntent.t(), state: String.t()}]}
          | {:error, :unauthorized}
  def list_intents(%Scope{} = scope, opts \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      limit = opts |> Keyword.get(:limit, 100) |> min(100)

      query =
        from i in InvoiceIntent,
          join: l in IntentLifecycle,
          on: l.invoice_intent_id == i.id,
          where: i.team_id == ^Scope.team_id!(scope),
          order_by: [desc: i.created_at],
          limit: ^limit,
          select: {i, l.current_state}

      query =
        case Keyword.get(opts, :customer_id) do
          nil -> query
          customer_id -> where(query, [i], i.customer_id == ^customer_id)
        end

      query =
        case Keyword.get(opts, :state) do
          nil -> query
          state -> where(query, [_i, l], l.current_state == ^state)
        end

      rows = Repo.all(query)
      {:ok, Enum.map(rows, fn {intent, state} -> %{intent: intent, state: state} end)}
    end
  end

  @doc """
  Append-only lifecycle transition history of an intent, oldest first
  (BC-US-112 evidence rendering).
  """
  @spec list_intent_transitions(Scope.t(), InvoiceIntent.t()) ::
          {:ok, [map()]} | {:error, :unauthorized}
  def list_intent_transitions(%Scope{} = scope, %InvoiceIntent{} = intent) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- ensure_team(scope, intent.team_id) do
      {:ok,
       Repo.all(
         from t in "invoice_intent_state_transitions",
           prefix: "billing",
           where: t.invoice_intent_id == type(^intent.id, Ecto.UUID),
           order_by: [asc: t.occurred_at],
           select: %{
             from_state: t.from_state,
             to_state: t.to_state,
             event: t.event,
             actor_type: t.actor_type,
             actor_id: t.actor_id,
             reason: t.reason,
             occurred_at: t.occurred_at
           }
       )}
    end
  end

  ## Charges

  @doc """
  Persists an immutable rated charge. The active-occurrence unique index is
  the double-billing guard (SPEC §18.4): a second active charge for the same
  occurrence returns `{:error, :occurrence_already_billed}`.
  """
  @spec record_charge!(Scope.t() | :system, map()) ::
          {:ok, Charge.t()} | {:error, :occurrence_already_billed}
  def record_charge!(_actor, attrs) do
    charge = struct!(Charge, attrs)

    case Repo.insert(charge) do
      {:ok, inserted} ->
        {:ok, inserted}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :occurrence_key),
          do: {:error, :occurrence_already_billed},
          else: raise("unexpected charge insert failure: #{inspect(errors)}")
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint == "charges_active_occurrence_uq",
        do: {:error, :occurrence_already_billed},
        else: reraise(e, __STACKTRACE__)
  end

  ## Invoice intent

  @doc """
  Freezes lines into a new immutable invoice intent in a new chain
  (BC-US-069). `attrs` requires `customer_id`, `customer_version`,
  `customer_external_id`, `customer_legal_name`, `currency`, `invoice_date`,
  `usage_cutoff`, and `lines` (maps with `line_key`, `product_id`,
  `product_version`, `description`, `quantity`, `amount_minor`,
  `recognition_mode`, optional service period, `calculation_trace`,
  `ordinal`, optional `erp_product_number`, `source_charge_id`).
  """
  @spec freeze_invoice_intent(Scope.t(), map()) ::
          {:ok, InvoiceIntent.t()} | {:error, term()}
  def freeze_invoice_intent(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, [:finance_operator, :billing_admin]),
         :ok <- validate_lines(attrs) do
      Repo.transaction(fn ->
        team_id = Scope.team_id!(scope)
        chain = Repo.insert!(%InvoiceChain{team_id: team_id, status: "active"})

        intent = insert_intent!(scope, chain, 1, nil, attrs)

        chain
        |> Ecto.Changeset.change(current_intent_id: intent.id)
        |> Repo.update!()

        intent
      end)
      |> case do
        {:ok, intent} -> {:ok, intent}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Replaces a frozen, unsynchronized intent with a new version in the same
  chain (BC-US-100). The old intent transitions to `superseded` and remains
  immutable.
  """
  @spec supersede_invoice_intent(Scope.t(), InvoiceIntent.t(), map()) ::
          {:ok, InvoiceIntent.t()} | {:error, term()}
  def supersede_invoice_intent(%Scope{} = scope, %InvoiceIntent{} = old_intent, attrs) do
    with :ok <- authorize(scope, [:finance_operator, :billing_admin]),
         :ok <- ensure_team(scope, old_intent.team_id),
         :ok <- validate_lines(attrs) do
      Repo.transaction(fn ->
        lifecycle = lock_lifecycle!(old_intent.id)

        case IntentMachine.transition(lifecycle.current_state, :supersede) do
          {:ok, :superseded} ->
            apply_lifecycle_transition!(scope, old_intent, lifecycle, :supersede, :superseded,
              reason: Map.get(attrs, :reason)
            )

            chain =
              Repo.one!(
                from c in InvoiceChain,
                  where: c.id == ^old_intent.invoice_chain_id,
                  lock: "FOR UPDATE"
              )

            intent =
              insert_intent!(scope, chain, old_intent.intent_version + 1, old_intent.id, attrs)

            chain
            |> Ecto.Changeset.change(current_intent_id: intent.id, version: chain.version + 1)
            |> Repo.update!()

            Outbox.emit!("invoice_intent.superseded.v1",
              aggregate: {:invoice_intent, old_intent.id},
              team_id: old_intent.team_id,
              correlation_id: scope.correlation_id,
              payload: %{replacement_intent_id: intent.id}
            )

            intent

          {:error, error} ->
            Repo.rollback({:illegal_state, error})
        end
      end)
    end
  end

  @doc """
  Applies a lifecycle event to an intent with optimistic locking and
  append-only evidence. Events per SPEC §11.2 via `IntentMachine`.

  An illegal transition returns `{:error, {:illegal_state, error}}` without
  aborting the surrounding database transaction — callers such as the sync
  worker invoke this inside their own transaction and tolerate the illegal
  case idempotently (INV-015), so the rejection must not poison their
  transaction (nothing has been written when the check fails; the row lock
  simply releases).
  """
  @spec transition_intent(Scope.t() | :system, InvoiceIntent.t(), atom(), keyword()) ::
          {:ok, IntentLifecycle.t()} | {:error, term()}
  def transition_intent(actor, %InvoiceIntent{} = intent, event, opts \\ []) do
    {:ok, result} =
      Repo.transaction(fn ->
        lifecycle = lock_lifecycle!(intent.id)

        case IntentMachine.transition(lifecycle.current_state, event) do
          {:ok, to_state} ->
            {:ok, apply_lifecycle_transition!(actor, intent, lifecycle, event, to_state, opts)}

          {:error, error} ->
            {:error, {:illegal_state, error}}
        end
      end)

    result
  end

  @doc "Loads an intent with lines, team-scoped."
  @spec get_intent(Scope.t(), Ecto.UUID.t()) :: {:ok, InvoiceIntent.t()} | {:error, :not_found}
  def get_intent(%Scope{} = scope, id) do
    team_id = Scope.team_id!(scope)

    case Repo.one(
           from i in InvoiceIntent,
             where: i.id == ^id and i.team_id == ^team_id,
             preload: [:lines]
         ) do
      nil -> {:error, :not_found}
      intent -> {:ok, intent}
    end
  end

  @doc "Current lifecycle state of an intent."
  @spec intent_state(InvoiceIntent.t()) :: String.t()
  def intent_state(%InvoiceIntent{id: id}) do
    Repo.get!(IntentLifecycle, id).current_state
  end

  ## Internals

  defp insert_intent!(scope, chain, version, supersedes_id, attrs) do
    team_id = chain.team_id
    intent_id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    lines = attrs |> Map.fetch!(:lines) |> Enum.sort_by(& &1.ordinal)
    currency = Map.fetch!(attrs, :currency)

    net =
      lines
      |> Enum.map(&Money.new!(currency, &1.amount_minor))
      |> Money.sum!(currency)

    snapshot = build_snapshot(intent_id, team_id, attrs, lines, net)

    # BC-US-108: reserve + finalize customer credit atomically with the
    # freeze; the ledger rows reference this intent.
    credit = Map.get(attrs, :credit_application)

    snapshot =
      case credit do
        %{amount_minor: applied} when applied > 0 ->
          snapshot
          |> Map.put("creditAppliedMinor", applied)
          |> Map.put("amountDueMinor", net.minor_units - applied)

        _ ->
          snapshot
      end

    content_hash = Canonical.hash(snapshot)

    intent =
      Repo.insert!(%InvoiceIntent{
        id: intent_id,
        team_id: team_id,
        invoice_chain_id: chain.id,
        billing_run_id: Map.get(attrs, :billing_run_id),
        customer_id: Map.fetch!(attrs, :customer_id),
        customer_version: Map.fetch!(attrs, :customer_version),
        contract_id: Map.get(attrs, :contract_id),
        currency: currency,
        invoice_date: Map.fetch!(attrs, :invoice_date),
        intent_version: version,
        supersedes_invoice_intent_id: supersedes_id,
        document_kind: Map.get(attrs, :document_kind, "invoice"),
        canonical_snapshot: Jason.decode!(Canonical.encode!(snapshot)),
        content_hash: content_hash,
        net_amount_minor: net.minor_units,
        created_at: now,
        frozen_at: now
      })

    for line <- lines do
      Repo.insert!(%InvoiceLine{
        team_id: team_id,
        invoice_intent_id: intent.id,
        line_key: line.line_key,
        source_charge_id: Map.get(line, :source_charge_id),
        adjusts_line_id: Map.get(line, :adjusts_line_id),
        product_id: line.product_id,
        product_version: line.product_version,
        description: line.description,
        quantity: line.quantity,
        display_unit: Map.get(line, :display_unit),
        amount_minor: line.amount_minor,
        currency: currency,
        recognition_mode: to_string(line.recognition_mode),
        service_start: Map.get(line, :service_start),
        service_end_exclusive: Map.get(line, :service_end_exclusive),
        calculation_trace: Map.get(line, :calculation_trace, %{}),
        ordinal: line.ordinal,
        created_at: now
      })
    end

    case credit do
      %{credit_account: account, amount_minor: applied} when applied > 0 ->
        {:ok, allocations} =
          BillingCore.Credits.reserve(scope, account, applied, "intent:#{intent.id}:reserve",
            invoice_intent_id: intent.id,
            reason_code: "invoice_application"
          )

        {:ok, _} =
          BillingCore.Credits.apply_reservation(
            scope,
            account,
            allocations,
            "intent:#{intent.id}:apply",
            invoice_intent_id: intent.id,
            reason_code: "invoice_application"
          )

        # SPEC §9.4.1: every application opens exactly one receivable
        # settlement in the same transaction; freezing rolls back when no
        # settlement mode is certified.
        BillingCore.Credits.Settlements.record_application!(
          scope,
          intent.id,
          account,
          applied,
          currency
        )

      _ ->
        :ok
    end

    Repo.insert!(%IntentLifecycle{
      invoice_intent_id: intent.id,
      team_id: team_id,
      current_state: "frozen"
    })

    Repo.insert_all(
      "invoice_intent_state_transitions",
      [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          invoice_intent_id: Ecto.UUID.dump!(intent.id),
          from_state: "preview",
          to_state: "frozen",
          event: "freeze",
          actor_type: actor_type(scope),
          actor_id: actor_id(scope),
          occurred_at: now
        }
      ],
      prefix: "billing"
    )

    Audit.record!(scope, "billing.invoice_intent.frozen",
      aggregate: {:invoice_intent, intent.id},
      payload: %{content_hash: content_hash, net_amount_minor: net.minor_units}
    )

    Outbox.emit!("invoice_intent.frozen.v1",
      aggregate: {:invoice_intent, intent.id},
      team_id: team_id,
      aggregate_version: version,
      correlation_id: correlation_id(scope),
      payload: %{
        invoice_chain_id: chain.id,
        content_hash: content_hash,
        net_amount_minor: net.minor_units
      }
    )

    intent
  end

  defp build_snapshot(intent_id, team_id, attrs, lines, net) do
    %{
      "schemaVersion" => 1,
      "invoiceIntentId" => intent_id,
      "teamId" => team_id,
      "customer" => %{
        "internalId" => Map.fetch!(attrs, :customer_id),
        "version" => Map.fetch!(attrs, :customer_version),
        "externalId" => Map.fetch!(attrs, :customer_external_id),
        "legalName" => Map.fetch!(attrs, :customer_legal_name)
      },
      "invoiceDate" => Map.fetch!(attrs, :invoice_date),
      "currency" => Map.fetch!(attrs, :currency),
      "usageCutoff" => Map.fetch!(attrs, :usage_cutoff),
      "lines" =>
        Enum.map(lines, fn line ->
          base = %{
            "lineKey" => line.line_key,
            "productId" => line.product_id,
            "productVersion" => line.product_version,
            "description" => line.description,
            "quantity" => line.quantity,
            "amountMinor" => line.amount_minor,
            "recognition" => recognition_snapshot(line)
          }

          case Map.get(line, :erp_product_number) do
            nil -> base
            number -> Map.put(base, "erpProductNumber", number)
          end
        end),
      "netAmountMinor" => net.minor_units
    }
  end

  defp recognition_snapshot(%{recognition_mode: mode} = line) do
    case to_string(mode) do
      "point_in_time" ->
        %{"mode" => "point_in_time"}

      "over_time" ->
        %{
          "mode" => "over_time",
          "serviceStart" => Map.fetch!(line, :service_start),
          "serviceEndExclusive" => Map.fetch!(line, :service_end_exclusive)
        }
    end
  end

  defp apply_lifecycle_transition!(actor, intent, lifecycle, event, to_state, opts) do
    now = DateTime.utc_now()

    updated =
      lifecycle
      |> Ecto.Changeset.change(
        current_state: to_string(to_state),
        latest_operation_id: Keyword.get(opts, :operation_id, lifecycle.latest_operation_id)
      )
      |> Ecto.Changeset.optimistic_lock(:version)
      |> Repo.update!()

    Repo.insert_all(
      "invoice_intent_state_transitions",
      [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          invoice_intent_id: Ecto.UUID.dump!(intent.id),
          from_state: lifecycle.current_state,
          to_state: to_string(to_state),
          event: to_string(event),
          actor_type: actor_type(actor),
          actor_id: actor_id(actor),
          reason: opts[:reason],
          causation_id: opts[:causation_id],
          occurred_at: now
        }
      ],
      prefix: "billing"
    )

    emit_transition_event(intent, to_state, opts)
    updated
  end

  defp emit_transition_event(intent, to_state, opts) do
    event_type =
      case to_state do
        :erp_draft -> "erp_document.draft_reconciled.v1"
        :approved -> "erp_document.approved.v1"
        :erp_booked -> "erp_document.booked.v1"
        _ -> nil
      end

    if event_type do
      Outbox.emit!(event_type,
        aggregate: {:invoice_intent, intent.id},
        team_id: intent.team_id,
        causation_id: opts[:causation_id],
        payload: %{state: to_string(to_state)}
      )
    end
  end

  defp lock_lifecycle!(intent_id) do
    Repo.one!(
      from l in IntentLifecycle, where: l.invoice_intent_id == ^intent_id, lock: "FOR UPDATE"
    )
  end

  defp validate_lines(%{lines: lines, currency: currency}) when is_list(lines) and lines != [] do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      cond do
        not is_integer(line.amount_minor) ->
          {:halt, {:error, {:invalid_line, line.line_key, :amount_must_be_integer_minor_units}}}

        Map.get(line, :currency, currency) != currency ->
          {:halt, {:error, {:invalid_line, line.line_key, :currency_mismatch}}}

        to_string(line.recognition_mode) == "over_time" and
            (is_nil(Map.get(line, :service_start)) or
               is_nil(Map.get(line, :service_end_exclusive))) ->
          {:halt, {:error, {:invalid_line, line.line_key, :missing_service_period}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_lines(_), do: {:error, :lines_required}

  defp authorize(%Scope{} = scope, roles) do
    if Scope.has_team_role?(scope, roles), do: :ok, else: {:error, :unauthorized}
  end

  defp ensure_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :unauthorized}
  end

  defp actor_type(:system), do: "system"
  defp actor_type(%Scope{principal_type: :user}), do: "user"
  defp actor_type(%Scope{principal_type: :service}), do: "service"

  defp actor_id(:system), do: nil
  defp actor_id(%Scope{user: %{id: id}}), do: to_string(id)
  defp actor_id(%Scope{service_credential: %{id: id}}), do: to_string(id)
  defp actor_id(_), do: nil

  defp correlation_id(%Scope{correlation_id: cid}), do: cid
end
