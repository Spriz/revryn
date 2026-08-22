defmodule BillingCore.Credits do
  @moduledoc """
  Customer-credit subledger (SPEC §8.7 BC-US-107/108/109, §11.4, §13.3,
  INV-050…053).

  Customer credit is money-like value held in an append-only ledger, distinct
  from invoice/credit-note documents (INV-050). Rules enforced here:

    * all ledger math is integer minor units; every balance change is a
      `customer_credit_transactions` row committed atomically with the
      account/grant projection update (INV-051);
    * the credit-account row is locked `FOR UPDATE` for any mutation, so the
      projection can never go below zero under concurrent billing runs — the
      database `>= 0` checks are the backstop (INV-052, BC-US-108);
    * allocation is deterministic: earliest `expires_at` first (nulls last),
      then oldest `granted_at`, then grant id (INV-052);
    * every mutation is idempotent by caller-supplied key; multi-grant
      commands derive per-row keys and carry the caller's key as
      `metadata["batch_key"]` — replays return the original result without
      re-emitting evidence;
    * grant status changes follow the §11.4 projection machine
      (`grant_machine/0`); the ledger, not the projection, is the audit
      evidence;
    * refund and expiry are financially significant durable operations
      (`credit.refund` / `credit.expiry` rows via `BillingCore.Operations`)
      per §11.4 and BC-US-109;
    * disposition policies are immutable account-scoped versions (INV-053);
      `execute_disposition/2` applies the current policy to grants with
      spendable remainder;
    * `reconcile_account/1` recomputes both projections from the immutable
      ledger and fails loudly on divergence (SPEC §13.3).

  Mutations require the `finance_operator` or `billing_admin` team role;
  reads admit all team roles. Reservation/application/release, refund
  completion, expiry runs, and disposition execution also accept the
  `:system` actor for billing-run and scheduler call sites.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Operations, Outbox, Repo, Scope}
  alias BillingCore.Credits.CreditAccount
  alias BillingCore.Credits.CreditGrant
  alias BillingCore.Credits.CreditTransaction
  alias BillingCore.Credits.DispositionPolicyVersion
  alias BillingCore.Domain.{Money, StateMachine}
  alias BillingCore.Operations.Operation
  alias BillingCore.Orgs.Account
  alias BillingCore.Orgs.Team

  @mutation_roles [:finance_operator, :billing_admin]
  @read_roles @mutation_roles ++ [:team_admin, :auditor, :integration_client]

  # SPEC §11.4 customer-credit grant projection machine. Event names label
  # the normative mermaid edges; states map 1:1 to persisted statuses.
  @grant_machine StateMachine.new(:credit_grant,
                   initial: :available,
                   transitions: [
                     # billing run reserves
                     {:available, :reserve, :reserved},
                     # invoice abandoned / reservation released
                     {:reserved, :release, :available},
                     # partial application finalized
                     {:reserved, :apply_partial, :partially_spent},
                     # fully applied
                     {:reserved, :apply_full, :spent},
                     # direct partial application
                     {:available, :apply_partial, :partially_spent},
                     # reserve remainder
                     {:partially_spent, :reserve, :reserved},
                     # remainder applied
                     {:partially_spent, :apply_full, :spent},
                     # termination policy = refund
                     {:available, :request_refund, :refund_pending},
                     # refund remaining balance
                     {:partially_spent, :request_refund, :refund_pending},
                     # refund reconciled
                     {:refund_pending, :reconcile_refund, :refunded},
                     # termination policy = expire_after
                     {:available, :schedule_expiry, :expiry_scheduled},
                     # schedule remaining balance expiry
                     {:partially_spent, :schedule_expiry, :expiry_scheduled},
                     # authorized policy reversal before deadline
                     {:expiry_scheduled, :reverse_expiry, :available},
                     # deadline reached + accounting action recorded
                     {:expiry_scheduled, :expire, :expired}
                   ],
                   terminal: [:spent, :refunded, :expired]
                 )

  @doc "The §11.4 grant-projection lifecycle as a `BillingCore.Domain.StateMachine`."
  @spec grant_machine() :: StateMachine.t()
  def grant_machine, do: @grant_machine

  ## Accounts

  @doc """
  Fetches or creates the credit account for `(team, account, currency)`.

  The commercial account must belong to the scope's organization. Requires a
  mutation role because a missing account is created.
  """
  @spec get_or_create_account(Scope.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, CreditAccount.t()} | {:error, :unauthorized | :not_found | :invalid_currency}
  def get_or_create_account(%Scope{} = scope, account_id, currency) do
    with :ok <- authorize(scope, @mutation_roles),
         :ok <- validate_currency(currency),
         {:ok, account} <- fetch_org_account(scope, account_id) do
      team_id = Scope.team_id!(scope)

      case Repo.get_by(CreditAccount,
             team_id: team_id,
             account_id: account.id,
             currency: currency
           ) do
        %CreditAccount{} = existing ->
          {:ok, existing}

        nil ->
          Repo.transaction(fn ->
            Repo.insert!(
              %CreditAccount{team_id: team_id, account_id: account.id, currency: currency},
              on_conflict: :nothing,
              conflict_target: [:team_id, :account_id, :currency]
            )

            credit_account =
              Repo.get_by!(CreditAccount,
                team_id: team_id,
                account_id: account.id,
                currency: currency
              )

            Audit.record!(scope, "credits.account.created",
              aggregate: {:credit_account, credit_account.id},
              payload: %{account_id: account.id, currency: currency}
            )

            credit_account
          end)
      end
    end
  end

  @doc "Fetches one credit account of the scope's team."
  @spec get_credit_account(Scope.t(), Ecto.UUID.t()) ::
          {:ok, CreditAccount.t()} | {:error, :unauthorized | :not_found}
  def get_credit_account(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(CreditAccount, id: id, team_id: Scope.team_id!(scope)) do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end
  end

  @doc """
  Credit accounts reachable from a team-local billing customer through its
  `account_team_customers` projection (BC-US-108 UI surface; all team
  roles). Returns `{:ok, []}` when the customer is not linked to a
  commercial account or the account holds no credit accounts.
  """
  @spec list_accounts_for_customer(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [CreditAccount.t()]} | {:error, :unauthorized}
  def list_accounts_for_customer(%Scope{} = scope, customer_id) do
    with :ok <- authorize(scope, @read_roles) do
      team_id = Scope.team_id!(scope)

      account_id =
        Repo.one(
          from atc in "account_team_customers",
            prefix: "billing",
            where:
              atc.team_id == type(^team_id, Ecto.UUID) and
                atc.customer_id == type(^customer_id, Ecto.UUID),
            select: atc.account_id,
            limit: 1
        )

      case account_id do
        nil ->
          {:ok, []}

        account_id ->
          {:ok,
           Repo.all(
             from a in CreditAccount,
               where:
                 a.team_id == ^team_id and
                   a.account_id == type(^account_id, Ecto.UUID),
               order_by: [asc: a.currency]
           )}
      end
    end
  end

  @doc "Grants of a credit account in grant order (all team roles)."
  @spec list_grants(Scope.t(), CreditAccount.t()) ::
          {:ok, [CreditGrant.t()]} | {:error, :unauthorized | :not_found}
  def list_grants(%Scope{} = scope, %CreditAccount{} = account) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- ensure_actor_team(scope, account.team_id) do
      {:ok,
       Repo.all(
         from g in CreditGrant,
           where: g.credit_account_id == ^account.id,
           order_by: [asc: g.granted_at, asc: g.id]
       )}
    end
  end

  @doc "Ledger history of a credit account in occurrence order (all team roles)."
  @spec list_transactions(Scope.t(), CreditAccount.t()) ::
          {:ok, [CreditTransaction.t()]} | {:error, :unauthorized | :not_found}
  def list_transactions(%Scope{} = scope, %CreditAccount{} = account) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- ensure_actor_team(scope, account.team_id) do
      {:ok,
       Repo.all(
         from t in CreditTransaction,
           where: t.credit_account_id == ^account.id,
           order_by: [asc: t.occurred_at, asc: t.id]
       )}
    end
  end

  ## Granting (BC-US-107)

  @doc """
  Grants customer credit onto a credit account.

  Required attrs: `:credit_account_id`, `:origin_type` (one of
  `#{inspect(CreditGrant.origin_types())}`), `:amount_minor` (> 0),
  `:currency` (must equal the account currency), `:idempotency_key`.
  Optional: `:origin_id`, `:origin_invoice_line_id`, `:expires_at`,
  `:reason_code`, `:metadata`.

  Writes the grant row (status `available`, remaining = granted), the
  `grant` ledger transaction, and the `available_minor` increment in one
  transaction; audits and emits `customer_credit.granted.v1`. The grant is
  stamped with the current disposition policy version, if any (BC-US-109).
  Replaying the same idempotency key returns the original grant.
  """
  @spec grant_credit(Scope.t(), map() | keyword()) ::
          {:ok, CreditGrant.t()} | {:error, term()}
  def grant_credit(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @mutation_roles),
         :ok <- validate_grant_attrs(attrs) do
      team_id = Scope.team_id!(scope)

      transact(fn ->
        account = lock_account!(attrs.credit_account_id, team_id) || Repo.rollback(:not_found)

        if account.currency != attrs.currency do
          Repo.rollback(:currency_mismatch)
        end

        case find_transaction(team_id, attrs.idempotency_key) do
          %CreditTransaction{transaction_type: :grant, credit_account_id: acct_id} = tx
          when acct_id == account.id ->
            Repo.get!(CreditGrant, tx.grant_id)

          %CreditTransaction{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            insert_grant!(scope, account, attrs)
        end
      end)
    end
  end

  defp insert_grant!(scope, account, attrs) do
    now = DateTime.utc_now()
    policy = current_policy_row(account.team_id, account.account_id, now)

    grant =
      Repo.insert!(%CreditGrant{
        team_id: account.team_id,
        credit_account_id: account.id,
        origin_type: attrs.origin_type,
        origin_id: attrs[:origin_id],
        origin_invoice_line_id: attrs[:origin_invoice_line_id],
        granted_minor: attrs.amount_minor,
        currency: account.currency,
        granted_at: now,
        expires_at: attrs[:expires_at],
        disposition_policy_version_id: policy && policy.id,
        metadata: attrs[:metadata] || %{},
        status: :available,
        remaining_minor: attrs.amount_minor
      })

    ledger!(scope, account, :grant, %{
      grant_id: grant.id,
      amount_minor: attrs.amount_minor,
      idempotency_key: attrs.idempotency_key,
      reason_code: attrs[:reason_code],
      occurred_at: now
    })

    shift_account!(account, attrs.amount_minor, 0)

    Audit.record!(scope, "credits.grant.created",
      aggregate: {:credit_grant, grant.id},
      payload: %{
        credit_account_id: account.id,
        origin_type: grant.origin_type,
        amount_minor: grant.granted_minor,
        currency: grant.currency
      }
    )

    Outbox.emit!("customer_credit.granted.v1",
      aggregate: {:credit_grant, grant.id},
      team_id: account.team_id,
      correlation_id: scope.correlation_id,
      payload: %{
        credit_account_id: account.id,
        origin_type: grant.origin_type,
        origin_invoice_line_id: grant.origin_invoice_line_id,
        amount_minor: grant.granted_minor,
        currency: grant.currency,
        expires_at: grant.expires_at
      }
    )

    grant
  end

  ## Reservation lifecycle (BC-US-108)

  @doc """
  Reserves `amount_minor` of credit against eligible grants.

  Allocation order (INV-052): earliest `expires_at` first (nulls last), then
  oldest `granted_at`, then grant id. Partial multi-grant reservations are
  allowed; when eligible headroom is insufficient the whole reservation
  fails with `{:error, :insufficient_credit}` and nothing is written.

  Returns `{:ok, [{grant_id, amount_minor}]}`. Options: `:invoice_intent_id`
  (recorded on each ledger row), `:reason_code`. Replaying the key returns
  the original allocation.
  """
  @spec reserve(
          Scope.t() | :system,
          CreditAccount.t(),
          pos_integer(),
          String.t(),
          keyword()
        ) :: {:ok, [{Ecto.UUID.t(), pos_integer()}]} | {:error, term()}
  def reserve(actor, %CreditAccount{} = account, amount_minor, idempotency_key, opts \\ [])
      when is_integer(amount_minor) and is_binary(idempotency_key) do
    if amount_minor <= 0 do
      {:error, :invalid_amount}
    else
      with_locked_account(actor, account, fn locked ->
        case batch_allocations(locked, :reserve, idempotency_key) do
          [_ | _] = replay ->
            replay

          [] ->
            do_reserve(actor, locked, amount_minor, idempotency_key, opts)
        end
      end)
    end
  end

  defp do_reserve(actor, account, amount_minor, idempotency_key, opts) do
    now = DateTime.utc_now()

    grants =
      Repo.all(
        from g in CreditGrant,
          where: g.credit_account_id == ^account.id,
          where: g.status in [:available, :reserved, :partially_spent],
          where: g.remaining_minor > g.reserved_minor,
          where: is_nil(g.expires_at) or g.expires_at > ^now,
          order_by: [asc_nulls_last: g.expires_at, asc: g.granted_at, asc: g.id],
          lock: "FOR UPDATE"
      )

    case allocate(grants, amount_minor) do
      {:error, :insufficient_credit} ->
        Repo.rollback(:insufficient_credit)

      {:ok, allocations} ->
        record_reservation!(actor, account, allocations, amount_minor, idempotency_key, opts, now)
    end
  end

  defp record_reservation!(actor, account, allocations, amount_minor, idempotency_key, opts, now) do
    allocations
    |> Enum.with_index()
    |> Enum.each(fn {{grant, amount}, seq} ->
      ledger!(actor, account, :reserve, %{
        grant_id: grant.id,
        amount_minor: amount,
        idempotency_key: batch_row_key(:reserve, idempotency_key, seq),
        invoice_intent_id: opts[:invoice_intent_id],
        reason_code: opts[:reason_code],
        occurred_at: now,
        metadata: %{"batch_key" => idempotency_key, "seq" => seq}
      })

      reserve_grant!(grant, amount)
    end)

    shift_account!(account, -amount_minor, amount_minor)
    result = Enum.map(allocations, fn {grant, amount} -> {grant.id, amount} end)

    Audit.record!(actor, "credits.reserved",
      aggregate: {:credit_account, account.id},
      team_id: account.team_id,
      payload: %{
        amount_minor: amount_minor,
        idempotency_key: idempotency_key,
        allocations: allocation_payload(result)
      }
    )

    Outbox.emit!("customer_credit.reserved.v1",
      aggregate: {:credit_account, account.id},
      team_id: account.team_id,
      correlation_id: actor_correlation_id(actor),
      payload: %{
        amount_minor: amount_minor,
        currency: account.currency,
        invoice_intent_id: opts[:invoice_intent_id],
        allocations: allocation_payload(result)
      }
    )

    result
  end

  defp reserve_grant!(grant, amount) do
    update_grant!(grant, %{reserved_minor: grant.reserved_minor + amount}, fn g ->
      if g.status == :reserved, do: g.status, else: grant_status!(g, :reserve)
    end)
  end

  @doc """
  Deterministic allocation of `amount_minor` across `grants` in the given
  order. Pure. Returns `{:ok, [{grant, amount}]}` covering exactly the
  requested amount, or `{:error, :insufficient_credit}` when the grants'
  headroom (`remaining - reserved`) cannot cover it.
  """
  @spec allocate([CreditGrant.t()], pos_integer()) ::
          {:ok, [{CreditGrant.t(), pos_integer()}]} | {:error, :insufficient_credit}
  def allocate(grants, amount_minor) when is_integer(amount_minor) and amount_minor > 0 do
    {allocations, remaining} =
      Enum.reduce_while(grants, {[], amount_minor}, fn grant, {acc, needed} ->
        take = min(CreditGrant.headroom(grant), needed)

        cond do
          take <= 0 -> {:cont, {acc, needed}}
          take == needed -> {:halt, {[{grant, take} | acc], 0}}
          true -> {:cont, {[{grant, take} | acc], needed - take}}
        end
      end)

    if remaining == 0 do
      {:ok, Enum.reverse(allocations)}
    else
      {:error, :insufficient_credit}
    end
  end

  @doc """
  Releases a reservation (abandoned invoice, BC-US-108).

  `reservation` is either the reservation's idempotency key or an explicit
  `[{grant_id, amount_minor}]` list. Writes `release` ledger rows and moves
  the amounts reserved → available. Idempotent by `idempotency_key`; a
  replay returns the original released allocation.
  """
  @spec release(
          Scope.t() | :system,
          CreditAccount.t(),
          String.t() | [{Ecto.UUID.t(), pos_integer()}],
          String.t()
        ) :: {:ok, [{Ecto.UUID.t(), pos_integer()}]} | {:error, term()}
  def release(actor, %CreditAccount{} = account, reservation, idempotency_key)
      when is_binary(idempotency_key) do
    with_locked_account(actor, account, fn locked ->
      case batch_allocations(locked, :release, idempotency_key) do
        [_ | _] = replay ->
          replay

        [] ->
          case resolve_reservation(locked, reservation) do
            [] -> Repo.rollback(:unknown_reservation)
            allocations -> unwind(actor, locked, :release, allocations, idempotency_key, [])
          end
      end
    end)
  end

  @doc """
  Finalizes a reservation when the invoice intent freezes (BC-US-108).

  Writes `apply` ledger rows, decrements the account's `reserved_minor` and
  each grant's `remaining_minor`, and moves grant statuses per §11.4
  (`spent` / `partially_spent`). Options: `:invoice_intent_id`,
  `:reason_code`. Idempotent by `idempotency_key`.
  """
  @spec apply_reservation(
          Scope.t() | :system,
          CreditAccount.t(),
          [{Ecto.UUID.t(), pos_integer()}],
          String.t(),
          keyword()
        ) :: {:ok, [{Ecto.UUID.t(), pos_integer()}]} | {:error, term()}
  def apply_reservation(
        actor,
        %CreditAccount{} = account,
        allocations,
        idempotency_key,
        opts \\ []
      )
      when is_list(allocations) and is_binary(idempotency_key) do
    with_locked_account(actor, account, fn locked ->
      case batch_allocations(locked, :apply, idempotency_key) do
        [_ | _] = replay -> replay
        [] -> unwind(actor, locked, :apply, allocations, idempotency_key, opts)
      end
    end)
  end

  # Shared release/apply core: both consume reserved amounts per grant.
  defp unwind(_actor, _account, _type, [], _idempotency_key, _opts) do
    Repo.rollback(:empty_allocations)
  end

  defp unwind(actor, account, type, allocations, idempotency_key, opts) do
    now = DateTime.utc_now()
    grants = lock_grants!(account, Enum.map(allocations, &elem(&1, 0)))
    total = allocations |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    allocations
    |> Enum.with_index()
    |> Enum.each(fn {{grant_id, amount}, seq} ->
      grant = Map.fetch!(grants, grant_id)

      if amount <= 0 or grant.reserved_minor < amount do
        Repo.rollback({:invalid_reservation_amount, grant_id})
      end

      ledger!(actor, account, type, %{
        grant_id: grant.id,
        amount_minor: amount,
        idempotency_key: batch_row_key(type, idempotency_key, seq),
        invoice_intent_id: opts[:invoice_intent_id],
        reason_code: opts[:reason_code],
        occurred_at: now,
        metadata: %{"batch_key" => idempotency_key, "seq" => seq}
      })

      unwind_grant!(type, grant, amount)
    end)

    unwind_shift_account!(account, type, total)

    {event, audit_event} = unwind_event_names(type)

    Audit.record!(actor, audit_event,
      aggregate: {:credit_account, account.id},
      team_id: account.team_id,
      payload: %{
        amount_minor: total,
        idempotency_key: idempotency_key,
        allocations: allocation_payload(allocations)
      }
    )

    Outbox.emit!(event,
      aggregate: {:credit_account, account.id},
      team_id: account.team_id,
      correlation_id: actor_correlation_id(actor),
      payload: %{
        amount_minor: total,
        currency: account.currency,
        invoice_intent_id: opts[:invoice_intent_id],
        allocations: allocation_payload(allocations)
      }
    )

    allocations
  end

  defp unwind_grant!(:release, grant, amount) do
    update_grant!(grant, %{reserved_minor: grant.reserved_minor - amount}, fn g ->
      if g.reserved_minor == 0, do: grant_status!(g, :release), else: g.status
    end)
  end

  defp unwind_grant!(:apply, grant, amount) do
    update_grant!(
      grant,
      %{
        reserved_minor: grant.reserved_minor - amount,
        remaining_minor: grant.remaining_minor - amount
      },
      fn g ->
        cond do
          g.remaining_minor == 0 -> grant_status!(g, :apply_full)
          g.reserved_minor == 0 -> grant_status!(g, :apply_partial)
          true -> g.status
        end
      end
    )
  end

  defp unwind_shift_account!(account, :release, total), do: shift_account!(account, total, -total)
  defp unwind_shift_account!(account, :apply, total), do: shift_account!(account, 0, -total)

  defp unwind_event_names(:release), do: {"customer_credit.released.v1", "credits.released"}
  defp unwind_event_names(:apply), do: {"customer_credit.applied.v1", "credits.applied"}

  ## Refund flow (BC-US-109)

  @doc """
  Requests a refund of the remaining balance of `grant_ids` (BC-US-109).

  Creates a durable `credit.refund` operation, moves each grant to
  `refund_pending` (§11.4), audits, and emits
  `customer_credit.refund_requested.v1`. No ledger row is written until the
  refund completes — pending grants stay in `available_minor` but are no
  longer eligible for reservation. The payment rail itself is adapter-driven
  and outside Billing Core.
  """
  @spec request_refund(Scope.t() | :system, CreditAccount.t(), [Ecto.UUID.t()]) ::
          {:ok, Operation.t()} | {:error, term()}
  def request_refund(actor, %CreditAccount{} = account, grant_ids) when is_list(grant_ids) do
    with_locked_account(actor, account, fn locked ->
      locked_grants = lock_grants!(locked, grant_ids)
      grants = Enum.map(grant_ids, &Map.fetch!(locked_grants, &1))

      total =
        Enum.reduce(grants, 0, fn grant, acc ->
          if grant.remaining_minor == 0, do: Repo.rollback({:nothing_to_refund, grant.id})
          acc + grant.remaining_minor
        end)

      operation =
        Operations.create!(%{
          team_id: locked.team_id,
          organization_id: actor_organization_id(actor),
          type: "credit.refund",
          actor_type: actor_type(actor),
          actor_id: actor_id(actor),
          target_type: "credit_account",
          target_id: locked.id,
          correlation_id: actor_correlation_id(actor),
          metadata: %{
            "grant_ids" => Enum.map(grants, & &1.id),
            "total_minor" => total,
            "currency" => locked.currency
          }
        })

      Enum.each(grants, fn grant ->
        update_grant!(grant, %{}, &grant_status!(&1, :request_refund))
      end)

      Audit.record!(actor, "credits.refund.requested",
        aggregate: {:credit_account, locked.id},
        team_id: locked.team_id,
        payload: %{
          operation_id: operation.id,
          grant_ids: Enum.map(grants, & &1.id),
          total_minor: total
        }
      )

      Outbox.emit!("customer_credit.refund_requested.v1",
        aggregate: {:credit_account, locked.id},
        team_id: locked.team_id,
        correlation_id: actor_correlation_id(actor),
        payload: %{
          operation_id: operation.id,
          grant_ids: Enum.map(grants, & &1.id),
          total_minor: total,
          currency: locked.currency
        }
      )

      operation
    end)
  end

  @doc """
  Completes a `credit.refund` operation: writes `refund` ledger rows that
  zero each pending grant's remainder and decrement `available_minor`, moves
  the grants to `refunded`, emits `customer_credit.refunded.v1`, and
  transitions the operation to `succeeded`. Idempotent: a replay (operation
  already succeeded, or refund ledger rows already present) returns the
  recorded result.
  """
  @spec complete_refund(Scope.t() | :system, Operation.t(), String.t()) ::
          {:ok, %{operation: Operation.t(), refunds: [{Ecto.UUID.t(), pos_integer()}]}}
          | {:error, term()}
  def complete_refund(actor, %Operation{type: "credit.refund"} = operation, idempotency_key)
      when is_binary(idempotency_key) do
    with :ok <- authorize_actor(actor),
         {:ok, account} <- fetch_operation_account(operation) do
      with_locked_account(actor, account, fn locked ->
        case refund_rows(operation) do
          [_ | _] = rows ->
            %{operation: Operations.get!(operation.id), refunds: rows}

          [] ->
            do_complete_refund(actor, locked, operation, idempotency_key)
        end
      end)
    end
  end

  defp do_complete_refund(actor, account, operation, idempotency_key) do
    if operation.state not in ["queued", "executing"] do
      Repo.rollback({:invalid_operation_state, operation.state})
    end

    operation =
      if operation.state == "queued",
        do: Operations.transition!(operation, :claim),
        else: operation

    now = DateTime.utc_now()
    grant_ids = operation.metadata["grant_ids"] || []
    grants = account |> lock_grants!(grant_ids) |> Map.values()

    refunds =
      grants
      |> Enum.with_index()
      |> Enum.map(fn {grant, seq} ->
        if grant.status != :refund_pending do
          Repo.rollback({:grant_not_refund_pending, grant.id})
        end

        amount = grant.remaining_minor

        ledger!(actor, account, :refund, %{
          grant_id: grant.id,
          amount_minor: amount,
          idempotency_key: batch_row_key(:refund, idempotency_key, seq),
          operation_id: operation.id,
          occurred_at: now,
          metadata: %{"batch_key" => idempotency_key, "seq" => seq}
        })

        update_grant!(grant, %{remaining_minor: 0}, &grant_status!(&1, :reconcile_refund))
        {grant.id, amount}
      end)

    total = refunds |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    shift_account!(account, -total, 0)

    Audit.record!(actor, "credits.refund.completed",
      aggregate: {:credit_account, account.id},
      team_id: account.team_id,
      payload: %{operation_id: operation.id, refunds: allocation_payload(refunds)}
    )

    Outbox.emit!("customer_credit.refunded.v1",
      aggregate: {:credit_account, account.id},
      team_id: account.team_id,
      correlation_id: actor_correlation_id(actor),
      payload: %{
        operation_id: operation.id,
        total_minor: total,
        currency: account.currency,
        refunds: allocation_payload(refunds)
      }
    )

    %{operation: Operations.transition!(operation, :succeed), refunds: refunds}
  end

  ## Expiry flow (BC-US-109)

  @doc """
  Schedules expiry of a grant's remaining balance at `expire_at`.

  Moves the grant to `expiry_scheduled` (§11.4), sets `expires_at` to the
  deadline (the operator/customer-visible scheduled expiry), creates a
  durable `credit.expiry` operation, audits, and emits
  `customer_credit.expiry_scheduled.v1`. The write-off itself is posted only
  after the deadline by `run_expiries/2`.
  """
  @spec schedule_expiry(Scope.t() | :system, CreditGrant.t(), DateTime.t()) ::
          {:ok, %{grant: CreditGrant.t(), operation: Operation.t()}} | {:error, term()}
  def schedule_expiry(actor, %CreditGrant{} = grant, %DateTime{} = expire_at) do
    with {:ok, account} <- fetch_credit_account(grant.credit_account_id) do
      with_locked_account(actor, account, fn locked ->
        grant = locked |> lock_grants!([grant.id]) |> Map.fetch!(grant.id)

        if grant.remaining_minor == 0 do
          Repo.rollback({:nothing_to_expire, grant.id})
        end

        operation =
          Operations.create!(%{
            team_id: locked.team_id,
            organization_id: actor_organization_id(actor),
            type: "credit.expiry",
            actor_type: actor_type(actor),
            actor_id: actor_id(actor),
            target_type: "credit_grant",
            target_id: grant.id,
            correlation_id: actor_correlation_id(actor),
            metadata: %{
              "grant_id" => grant.id,
              "expire_at" => DateTime.to_iso8601(expire_at),
              "amount_minor" => grant.remaining_minor
            }
          })

        metadata =
          grant.metadata
          |> Map.put("expiry_operation_id", operation.id)
          |> Map.put(
            "expiry_original_expires_at",
            grant.expires_at && DateTime.to_iso8601(grant.expires_at)
          )

        updated =
          update_grant!(
            grant,
            %{expires_at: expire_at, metadata: metadata},
            &grant_status!(&1, :schedule_expiry)
          )

        Audit.record!(actor, "credits.expiry.scheduled",
          aggregate: {:credit_grant, grant.id},
          team_id: locked.team_id,
          payload: %{operation_id: operation.id, expire_at: expire_at}
        )

        Outbox.emit!("customer_credit.expiry_scheduled.v1",
          aggregate: {:credit_grant, grant.id},
          team_id: locked.team_id,
          correlation_id: actor_correlation_id(actor),
          payload: %{
            credit_account_id: locked.id,
            operation_id: operation.id,
            expire_at: expire_at,
            amount_minor: grant.remaining_minor,
            currency: grant.currency
          }
        )

        %{grant: updated, operation: operation}
      end)
    end
  end

  @doc """
  Reverses a scheduled expiry before its deadline (authorized policy
  reversal, §11.4). The grant returns to `available` with its original
  `expires_at`; the pending `credit.expiry` operation is closed as failed
  with the reversal as evidence.
  """
  @spec reverse_expiry_schedule(Scope.t(), CreditGrant.t()) ::
          {:ok, CreditGrant.t()} | {:error, term()}
  def reverse_expiry_schedule(%Scope{} = scope, %CreditGrant{} = grant) do
    with {:ok, account} <- fetch_credit_account(grant.credit_account_id) do
      with_locked_account(scope, account, fn locked ->
        grant = locked |> lock_grants!([grant.id]) |> Map.fetch!(grant.id)

        original_expires_at =
          case grant.metadata["expiry_original_expires_at"] do
            nil -> nil
            iso -> elem(DateTime.from_iso8601(iso), 1)
          end

        operation_id = grant.metadata["expiry_operation_id"]

        metadata =
          grant.metadata
          |> Map.delete("expiry_operation_id")
          |> Map.delete("expiry_original_expires_at")

        updated =
          update_grant!(
            grant,
            %{expires_at: original_expires_at, metadata: metadata},
            &grant_status!(&1, :reverse_expiry)
          )

        fail_pending_expiry_operation!(operation_id)

        Audit.record!(scope, "credits.expiry.reversed",
          aggregate: {:credit_grant, grant.id},
          team_id: locked.team_id,
          payload: %{operation_id: operation_id}
        )

        updated
      end)
    end
  end

  defp fail_pending_expiry_operation!(nil), do: :ok

  defp fail_pending_expiry_operation!(operation_id) do
    operation = Operations.get!(operation_id)

    if operation.state == "queued" do
      operation
      |> Operations.transition!(:claim)
      |> Operations.transition!(:fail, %{
        safe_error_code: "expiry_reversed",
        safe_error_summary: "expiry schedule reversed before deadline"
      })
    end
  end

  @doc """
  Executes all due scheduled expiries at `now` (system sweep).

  For every `expiry_scheduled` grant whose deadline has passed, in its own
  transaction: claims the grant's `credit.expiry` operation, writes the
  `expire` ledger row (deterministic idempotency key), zeroes the remainder,
  decrements `available_minor`, moves the grant to `expired`, emits
  `customer_credit.expired.v1`, and succeeds the operation. Expiry is
  grant-aware: only the scheduled grant is forfeited (SPEC §13.3).
  """
  @spec run_expiries(:system, DateTime.t()) ::
          {:ok, [%{grant_id: Ecto.UUID.t(), amount_minor: pos_integer()}]}
  def run_expiries(:system, %DateTime{} = now) do
    due =
      Repo.all(
        from g in CreditGrant,
          where: g.status == :expiry_scheduled and g.expires_at <= ^now,
          select: g.id,
          order_by: [asc: g.expires_at, asc: g.id]
      )

    results =
      due
      |> Enum.map(&expire_grant(&1, now))
      |> Enum.reject(&is_nil/1)

    {:ok, results}
  end

  defp expire_grant(grant_id, now) do
    result = Repo.transaction(fn -> expire_grant_in_txn(grant_id, now) end)

    case result do
      {:ok, entry} -> entry
      {:error, _skipped} -> nil
    end
  end

  defp expire_grant_in_txn(grant_id, now) do
    grant = Repo.get!(CreditGrant, grant_id)
    account = lock_account!(grant.credit_account_id, grant.team_id)
    grant = account |> lock_grants!([grant_id]) |> Map.fetch!(grant_id)

    # Re-check under lock: the schedule may have been reversed meanwhile.
    if grant.status != :expiry_scheduled or DateTime.after?(grant.expires_at, now) do
      Repo.rollback(:not_due)
    end

    operation = claim_expiry_operation!(grant)
    amount = grant.remaining_minor

    write_expiry!(account, grant, operation, amount)
    succeed_expiry_operation!(operation)

    %{grant_id: grant.id, amount_minor: amount}
  end

  defp claim_expiry_operation!(grant) do
    operation =
      case grant.metadata["expiry_operation_id"] do
        nil -> nil
        id -> Operations.get!(id)
      end

    if operation && operation.state == "queued",
      do: Operations.transition!(operation, :claim),
      else: operation
  end

  defp write_expiry!(account, grant, operation, amount) do
    ledger!(:system, account, :expire, %{
      grant_id: grant.id,
      amount_minor: amount,
      idempotency_key: "credit_expiry:#{grant.id}",
      operation_id: operation && operation.id,
      occurred_at: DateTime.utc_now()
    })

    update_grant!(grant, %{remaining_minor: 0}, &grant_status!(&1, :expire))
    shift_account!(account, -amount, 0)

    Audit.record!(:system, "credits.expiry.executed",
      aggregate: {:credit_grant, grant.id},
      team_id: account.team_id,
      payload: %{operation_id: operation && operation.id, amount_minor: amount}
    )

    Outbox.emit!("customer_credit.expired.v1",
      aggregate: {:credit_grant, grant.id},
      team_id: account.team_id,
      payload: %{
        credit_account_id: account.id,
        operation_id: operation && operation.id,
        amount_minor: amount,
        currency: grant.currency
      }
    )
  end

  defp succeed_expiry_operation!(operation) do
    if operation && operation.state == "executing" do
      Operations.transition!(operation, :succeed)
    end
  end

  ## Disposition policies (BC-US-109, INV-053)

  @doc """
  Appends a new immutable disposition policy version for the credit
  account's commercial account. Attrs: `:policy` (`:retain` / `:refund` /
  `:expire_after`), `:expire_after_days` (required for `:expire_after`),
  `:effective_from` (defaults to now), `:contract_id` (informational).
  Versions are per `(team, account)` and never mutated (INV-053).
  """
  @spec set_disposition_policy(Scope.t(), CreditAccount.t(), map() | keyword()) ::
          {:ok, DispositionPolicyVersion.t()} | {:error, term()}
  def set_disposition_policy(%Scope{} = scope, %CreditAccount{} = account, attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:effective_from, DateTime.utc_now())

    with :ok <- authorize(scope, @mutation_roles),
         :ok <- ensure_actor_team(scope, account.team_id) do
      transact(fn ->
        # Serialize version assignment per commercial account.
        Repo.one!(from a in Account, where: a.id == ^account.account_id, lock: "FOR UPDATE")

        next_version =
          Repo.one(
            from p in DispositionPolicyVersion,
              where: p.team_id == ^account.team_id and p.account_id == ^account.account_id,
              select: coalesce(max(p.version), 0)
          ) + 1

        changeset =
          DispositionPolicyVersion.create_changeset(
            %DispositionPolicyVersion{
              team_id: account.team_id,
              account_id: account.account_id,
              version: next_version,
              created_by: scope.user && scope.user.id
            },
            attrs
          )

        case Repo.insert(changeset) do
          {:ok, policy} ->
            Audit.record!(scope, "credits.disposition_policy.set",
              aggregate: {:credit_account, account.id},
              payload: %{
                policy_version_id: policy.id,
                version: policy.version,
                policy: policy.policy,
                expire_after_days: policy.expire_after_days
              }
            )

            policy

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc """
  The currently effective disposition policy version for the credit
  account's commercial account: the highest version with `effective_from`
  in the past. Returns `{:ok, nil}` when none is configured.
  """
  @spec current_disposition_policy(Scope.t(), CreditAccount.t()) ::
          {:ok, DispositionPolicyVersion.t() | nil} | {:error, :unauthorized | :not_found}
  def current_disposition_policy(%Scope{} = scope, %CreditAccount{} = account) do
    with :ok <- authorize(scope, @read_roles),
         :ok <- ensure_actor_team(scope, account.team_id) do
      {:ok, current_policy_row(account.team_id, account.account_id, DateTime.utc_now())}
    end
  end

  @doc """
  Executes the current disposition policy against every grant of `account`
  with a spendable remainder (status `available` / `partially_spent`,
  remaining > 0). Grants tied up in active reservations are skipped —
  the in-flight billing run settles them first (INV-053).

    * `retain` — no-op; the balance stays eligible for later invoices;
    * `refund` — one durable `credit.refund` operation for the grants;
    * `expire_after` — schedules expiry at now + configured days per grant.

  Subscription-termination triggering is wired by the billing layer.
  """
  @spec execute_disposition(Scope.t() | :system, CreditAccount.t()) ::
          {:ok, map()} | {:error, term()}
  def execute_disposition(actor, %CreditAccount{} = account) do
    with :ok <- authorize_actor(actor),
         :ok <- ensure_actor_team(actor, account.team_id) do
      now = DateTime.utc_now()

      case current_policy_row(account.team_id, account.account_id, now) do
        nil ->
          {:error, :no_disposition_policy}

        %DispositionPolicyVersion{} = policy ->
          grant_ids =
            Repo.all(
              from g in CreditGrant,
                where: g.credit_account_id == ^account.id,
                where: g.status in [:available, :partially_spent],
                where: g.remaining_minor > 0,
                order_by: [asc: g.granted_at, asc: g.id],
                select: g.id
            )

          apply_disposition(actor, account, policy, grant_ids, now)
      end
    end
  end

  defp apply_disposition(_actor, _account, %{policy: :retain} = policy, grant_ids, _now) do
    {:ok, %{policy: :retain, policy_version: policy.version, retained_grant_ids: grant_ids}}
  end

  defp apply_disposition(_actor, _account, %{policy: policy_name} = policy, [], _now) do
    {:ok, %{policy: policy_name, policy_version: policy.version, action: :none}}
  end

  defp apply_disposition(actor, account, %{policy: :refund} = policy, grant_ids, _now) do
    with {:ok, operation} <- request_refund(actor, account, grant_ids) do
      {:ok, %{policy: :refund, policy_version: policy.version, operation: operation}}
    end
  end

  defp apply_disposition(actor, _account, %{policy: :expire_after} = policy, grant_ids, now) do
    expire_at = DateTime.add(now, policy.expire_after_days * 86_400, :second)

    scheduled =
      Enum.map(grant_ids, fn grant_id ->
        grant = Repo.get!(CreditGrant, grant_id)
        {:ok, %{operation: operation}} = schedule_expiry(actor, grant, expire_at)
        %{grant_id: grant_id, operation_id: operation.id}
      end)

    {:ok,
     %{
       policy: :expire_after,
       policy_version: policy.version,
       expire_at: expire_at,
       scheduled: scheduled
     }}
  end

  ## Reconciliation (SPEC §13.3, INV-051)

  @doc """
  Recomputes `available_minor` / `reserved_minor` and every grant's
  `remaining_minor` / `reserved_minor` from the immutable transaction ledger
  and compares them to the stored projections.

  Returns `:ok` when everything matches, `{:mismatch, details}` on any
  divergence — reconciliation must fail loudly (SPEC §13.3). The billing
  layer calls this in tests and health checks.
  """
  @spec reconcile_account(Ecto.UUID.t()) :: :ok | {:mismatch, map()} | {:error, :not_found}
  def reconcile_account(credit_account_id) do
    result =
      Repo.transaction(fn ->
        case Repo.get(CreditAccount, credit_account_id) do
          nil ->
            Repo.rollback(:not_found)

          account ->
            transactions =
              Repo.all(
                from t in CreditTransaction, where: t.credit_account_id == ^credit_account_id
              )

            grants =
              Repo.all(from g in CreditGrant, where: g.credit_account_id == ^credit_account_id)

            compare_projections(account, grants, transactions)
        end
      end)

    case result do
      {:ok, comparison} -> comparison
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Like `reconcile_account/1` but raises on divergence."
  @spec reconcile_account!(Ecto.UUID.t()) :: :ok
  def reconcile_account!(credit_account_id) do
    case reconcile_account(credit_account_id) do
      :ok ->
        :ok

      other ->
        raise "customer-credit ledger reconciliation failed for account " <>
                "#{credit_account_id}: #{inspect(other)}"
    end
  end

  defp compare_projections(account, grants, transactions) do
    sums = Enum.reduce(transactions, %{}, &accumulate_transaction/2)

    expected_available =
      total(sums, :grant) - total(sums, :reserve) + total(sums, :release) -
        total(sums, :refund) - total(sums, :expire) + total(sums, :adjust_available)

    expected_reserved =
      total(sums, :reserve) - total(sums, :release) - total(sums, :apply) +
        total(sums, :adjust_reserved)

    account_issues =
      %{}
      |> put_issue(:available_minor, expected_available, account.available_minor)
      |> put_issue(:reserved_minor, expected_reserved, account.reserved_minor)
      |> Map.merge(Map.get(sums, :unrecognized, []) |> unrecognized_issue())

    grant_issues =
      grants
      |> Enum.reduce(%{}, fn grant, acc ->
        per = Map.get(sums, {:grant_sums, grant.id}, %{})

        expected_remaining =
          Map.get(per, :grant, 0) - Map.get(per, :apply, 0) - Map.get(per, :refund, 0) -
            Map.get(per, :expire, 0)

        expected_grant_reserved =
          Map.get(per, :reserve, 0) - Map.get(per, :release, 0) - Map.get(per, :apply, 0)

        issues =
          %{}
          |> put_issue(:remaining_minor, expected_remaining, grant.remaining_minor)
          |> put_issue(:reserved_minor, expected_grant_reserved, grant.reserved_minor)

        if issues == %{}, do: acc, else: Map.put(acc, grant.id, issues)
      end)

    if account_issues == %{} and grant_issues == %{} do
      :ok
    else
      {:mismatch, %{account: account_issues, grants: grant_issues}}
    end
  end

  defp accumulate_transaction(tx, sums) do
    effect =
      case tx.transaction_type do
        :adjust -> adjust_effect(tx)
        type -> type
      end

    case effect do
      {:unrecognized, tx_id} ->
        Map.update(sums, :unrecognized, [tx_id], &[tx_id | &1])

      {key, signed_amount} ->
        Map.update(sums, key, signed_amount, &(&1 + signed_amount))

      type ->
        sums
        |> Map.update(type, tx.amount_minor, &(&1 + tx.amount_minor))
        |> accumulate_grant_sum(tx, type)
    end
  end

  defp accumulate_grant_sum(sums, tx, type) do
    if tx.grant_id do
      Map.update(
        sums,
        {:grant_sums, tx.grant_id},
        %{type => tx.amount_minor},
        &Map.update(&1, type, tx.amount_minor, fn n -> n + tx.amount_minor end)
      )
    else
      sums
    end
  end

  # Manual `adjust` rows must declare their target and direction; anything
  # else is itself a reconciliation failure.
  defp adjust_effect(tx) do
    sign =
      case tx.metadata["direction"] do
        "increase" -> 1
        "decrease" -> -1
        _ -> nil
      end

    case {tx.metadata["target"], sign} do
      {"available", sign} when is_integer(sign) -> {:adjust_available, sign * tx.amount_minor}
      {"reserved", sign} when is_integer(sign) -> {:adjust_reserved, sign * tx.amount_minor}
      _ -> {:unrecognized, tx.id}
    end
  end

  defp total(sums, key), do: Map.get(sums, key, 0)

  defp put_issue(issues, key, expected, actual) do
    if expected == actual do
      issues
    else
      Map.put(issues, key, %{expected: expected, actual: actual})
    end
  end

  defp unrecognized_issue([]), do: %{}
  defp unrecognized_issue(tx_ids), do: %{unrecognized_adjust_transactions: tx_ids}

  ## Shared internals

  defp validate_grant_attrs(attrs) do
    cond do
      is_nil(attrs[:credit_account_id]) ->
        {:error, :missing_credit_account_id}

      attrs[:origin_type] not in CreditGrant.origin_types() ->
        {:error, :invalid_origin_type}

      not (is_integer(attrs[:amount_minor]) and attrs[:amount_minor] > 0) ->
        {:error, :invalid_amount}

      not is_binary(attrs[:currency]) ->
        {:error, :invalid_currency}

      not is_binary(attrs[:idempotency_key]) or attrs[:idempotency_key] == "" ->
        {:error, :missing_idempotency_key}

      true ->
        :ok
    end
  end

  defp validate_currency(currency) do
    if Money.valid_currency?(currency), do: :ok, else: {:error, :invalid_currency}
  end

  defp fetch_org_account(scope, account_id) do
    org_id = Scope.organization_id!(scope)

    case Repo.get(Account, account_id) do
      %Account{organization_id: ^org_id} = account -> {:ok, account}
      _ -> {:error, :not_found}
    end
  end

  defp fetch_credit_account(credit_account_id) do
    case Repo.get(CreditAccount, credit_account_id) do
      nil -> {:error, :not_found}
      account -> {:ok, account}
    end
  end

  defp fetch_operation_account(%Operation{target_type: "credit_account", target_id: id})
       when not is_nil(id),
       do: fetch_credit_account(id)

  defp fetch_operation_account(%Operation{}), do: {:error, :invalid_operation_target}

  defp refund_rows(%Operation{id: operation_id}) do
    Repo.all(
      from t in CreditTransaction,
        where: t.operation_id == ^operation_id and t.transaction_type == :refund,
        order_by: [asc: fragment("(?->>'seq')::int", t.metadata)],
        select: {t.grant_id, t.amount_minor}
    )
  end

  # Every mutation runs with the account row locked FOR UPDATE, which
  # serializes all balance changes per account (BC-US-108 concurrency).
  defp with_locked_account(actor, %CreditAccount{} = account, fun) do
    with :ok <- authorize_actor(actor),
         :ok <- ensure_actor_team(actor, account.team_id) do
      transact(fn ->
        case lock_account!(account.id, account.team_id) do
          nil -> Repo.rollback(:not_found)
          locked -> fun.(locked)
        end
      end)
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_account!(account_id, team_id) do
    Repo.one(
      from a in CreditAccount,
        where: a.id == ^account_id and a.team_id == ^team_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_grants!(account, grant_ids) do
    grants =
      Repo.all(
        from g in CreditGrant,
          where: g.id in ^grant_ids and g.credit_account_id == ^account.id,
          lock: "FOR UPDATE"
      )

    found = Map.new(grants, &{&1.id, &1})

    case Enum.find(grant_ids, &(not Map.has_key?(found, &1))) do
      nil -> found
      missing -> Repo.rollback({:grant_not_found, missing})
    end
  end

  defp grant_status!(grant, event) do
    case StateMachine.transition(@grant_machine, grant.status, event) do
      {:ok, to} -> to
      {:error, error} -> Repo.rollback({:illegal_grant_transition, error})
    end
  end

  defp update_grant!(grant, changes, status_fun) do
    grant
    |> Ecto.Changeset.change(
      changes
      |> Map.put(:status, status_fun.(struct(grant, changes)))
      |> Map.put(:version, grant.version + 1)
    )
    |> Repo.update!()
  end

  defp shift_account!(account, available_delta, reserved_delta) do
    new_available = account.available_minor + available_delta
    new_reserved = account.reserved_minor + reserved_delta

    account
    |> Ecto.Changeset.change(
      available_minor: new_available,
      reserved_minor: new_reserved,
      version: account.version + 1
    )
    |> Ecto.Changeset.check_constraint(:available_minor,
      name: :customer_credit_accounts_available_check
    )
    |> Ecto.Changeset.check_constraint(:reserved_minor,
      name: :customer_credit_accounts_reserved_check
    )
    |> Repo.update!()
  end

  defp ledger!(actor, account, type, attrs) do
    Repo.insert!(%CreditTransaction{
      team_id: account.team_id,
      credit_account_id: account.id,
      grant_id: attrs[:grant_id],
      transaction_type: type,
      amount_minor: attrs.amount_minor,
      currency: account.currency,
      idempotency_key: attrs.idempotency_key,
      invoice_intent_id: attrs[:invoice_intent_id],
      operation_id: attrs[:operation_id],
      reason_code: attrs[:reason_code],
      actor_reference: actor_reference(actor),
      accounting_effective_on:
        accounting_effective_on!(actor, account.team_id, attrs.occurred_at),
      occurred_at: attrs.occurred_at,
      metadata: attrs[:metadata] || %{}
    })
  end

  defp find_transaction(team_id, idempotency_key) do
    Repo.get_by(CreditTransaction, team_id: team_id, idempotency_key: idempotency_key)
  end

  defp batch_row_key(type, batch_key, seq), do: "#{type}:#{batch_key}/#{seq}"

  defp batch_allocations(account, type, batch_key) do
    Repo.all(
      from t in CreditTransaction,
        where: t.credit_account_id == ^account.id and t.transaction_type == ^type,
        where: fragment("?->>'batch_key' = ?", t.metadata, ^batch_key),
        order_by: [asc: fragment("(?->>'seq')::int", t.metadata)],
        select: {t.grant_id, t.amount_minor}
    )
  end

  defp resolve_reservation(account, reservation_key) when is_binary(reservation_key) do
    batch_allocations(account, :reserve, reservation_key)
  end

  defp resolve_reservation(_account, allocations) when is_list(allocations), do: allocations

  defp allocation_payload(allocations) do
    Enum.map(allocations, fn {grant_id, amount} ->
      %{grant_id: grant_id, amount_minor: amount}
    end)
  end

  ## Actors

  defp authorize(%Scope{} = scope, roles) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, roles) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp authorize_actor(:system), do: :ok
  defp authorize_actor(%Scope{} = scope), do: authorize(scope, @mutation_roles)

  defp ensure_actor_team(:system, _team_id), do: :ok

  defp ensure_actor_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :not_found}
  end

  defp actor_type(:system), do: "system"
  defp actor_type(%Scope{principal_type: :user}), do: "user"
  defp actor_type(%Scope{principal_type: :service}), do: "service"

  defp actor_id(:system), do: nil
  defp actor_id(%Scope{principal_type: :user, user: %{id: id}}), do: to_string(id)

  defp actor_id(%Scope{principal_type: :service, service_credential: %{id: id}}),
    do: to_string(id)

  defp actor_id(%Scope{}), do: nil

  defp actor_reference(:system), do: "system"

  defp actor_reference(%Scope{} = scope) do
    case actor_id(scope) do
      nil -> actor_type(scope)
      id -> "#{actor_type(scope)}:#{id}"
    end
  end

  defp actor_correlation_id(:system), do: nil
  defp actor_correlation_id(%Scope{correlation_id: cid}), do: cid

  defp actor_organization_id(:system), do: nil
  defp actor_organization_id(%Scope{organization: %{id: id}}), do: id
  defp actor_organization_id(%Scope{}), do: nil

  defp accounting_effective_on!(
         %Scope{team: %{id: team_id, time_zone: time_zone}},
         team_id,
         occurred_at
       ) do
    local_date!(occurred_at, time_zone)
  end

  defp accounting_effective_on!(_actor, team_id, occurred_at) do
    team = Repo.get!(Team, team_id)
    local_date!(occurred_at, team.time_zone)
  end

  defp local_date!(occurred_at, time_zone) do
    case DateTime.shift_zone(occurred_at, time_zone) do
      {:ok, local} -> DateTime.to_date(local)
      {:error, reason} -> Repo.rollback({:invalid_accounting_time_zone, time_zone, reason})
    end
  end

  defp current_policy_row(team_id, account_id, now) do
    Repo.one(
      from p in DispositionPolicyVersion,
        where: p.team_id == ^team_id and p.account_id == ^account_id,
        where: p.effective_from <= ^now,
        order_by: [desc: p.version],
        limit: 1
    )
  end
end
