defmodule BillingCore.Contracts do
  @moduledoc """
  Customers, contracts, subscriptions, and one-time charge instances
  (SPEC §8.3 Epic C, §11.1, §13.3).

  Every public function takes a `BillingCore.Scope` as its first argument;
  mutations require the `billing_admin` or `team_admin` team role, reads also
  admit `finance_operator`, `auditor`, and `integration_client`. All queries
  are constrained by the scope's team.

  Structural rules enforced here:

    * customer facts are immutable versioned snapshots — an upsert with an
      unchanged canonical snapshot is a no-op (BC-US-030);
    * a subscription starts inside its contract dates, idempotently by
      external ID (BC-US-034); a future start is `scheduled` until
      `activate_due_subscriptions/1` promotes it (BC-US-035);
    * quantity/plan changes close the current subscription version at the
      effective date and append the successor — versions never overlap,
      enforced by a database exclusion constraint (BC-US-036/037);
    * lifecycle transitions follow the §11.1 state machine
      (`subscription_machine/0`); PostgreSQL remains the authority for
      durable state (INV-046/047);
    * every accepted command appends a `subscription_changes` row, an audit
      entry, and a versioned outbox event in one transaction;
    * one-time charge instances are idempotent by external charge ID:
      identical canonical replays return the original, different payloads are
      conflicts; cancellation is possible only while `pending` (BC-US-041).
  """

  import Ecto.Query

  alias BillingCore.{Audit, Outbox, Repo, Scope}
  alias BillingCore.Domain.{Canonical, StateMachine}

  alias BillingCore.Contracts.{
    ChargeInstance,
    Contract,
    ContractVersion,
    Customer,
    CustomerErpMapping,
    CustomerVersion,
    Subscription,
    SubscriptionChange,
    SubscriptionVersion
  }

  @write_roles [:billing_admin, :team_admin]
  @read_roles @write_roles ++ [:finance_operator, :auditor, :integration_client]

  @list_cap 100

  # SPEC §11.1 subscription state machine. Persisted status strings map 1:1
  # to these machine states via the schema's Ecto.Enum.
  @subscription_machine StateMachine.new(:subscription,
                          initial: :scheduled,
                          transitions: [
                            # start date reached
                            {:scheduled, :activate, :active},
                            # cancelled before start
                            {:scheduled, :cancel, :cancelled},
                            # quantity or plan version change
                            {:active, :change, :active},
                            # cancel at period end
                            {:active, :cancel_at_period_end, :pending_cancellation},
                            # immediate cancellation
                            {:active, :cancel, :cancelled},
                            {:active, :pause, :paused},
                            {:paused, :resume, :active},
                            # period boundary reached
                            {:pending_cancellation, :reach_period_boundary, :cancelled}
                          ],
                          terminal: [:cancelled]
                        )

  @doc "The §11.1 subscription lifecycle as a `BillingCore.Domain.StateMachine`."
  @spec subscription_machine() :: StateMachine.t()
  def subscription_machine, do: @subscription_machine

  ## Customers (BC-US-030)

  @doc """
  Creates or updates a customer by `(team, external_id)`.

  `attrs` is the full desired customer state: `:external_id`, `:legal_name`,
  `:country`, `:email` (required), `:address_line`, `:zip`, `:city`,
  `:vat_number`, `:currency_preference`, `:status` (optional). Every change
  writes a new immutable `customer_versions` snapshot (canonical SHA-256
  content hash), bumps `current_version`, audits, and emits
  `customer.version_created.v1`. When the canonical snapshot (including
  status) is unchanged the call is an idempotent no-op and `:version` is
  `nil`.
  """
  @spec upsert_customer(Scope.t(), map() | keyword()) ::
          {:ok, %{customer: Customer.t(), version: CustomerVersion.t() | nil}}
          | {:error, :unauthorized | Ecto.Changeset.t()}
  def upsert_customer(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        case lock_customer(team_id, attrs[:external_id]) do
          nil -> insert_customer(scope, team_id, attrs)
          %Customer{} = customer -> update_customer(scope, customer, attrs)
        end
      end)
    end
  end

  @doc "Fetches a customer of the scope's team."
  @spec get_customer(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Customer.t()} | {:error, :unauthorized | :not_found}
  def get_customer(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      fetch_team_row(Customer, Scope.team_id!(scope), id)
    end
  end

  @doc "Lists the team's customers ordered by external ID (capped at #{@list_cap})."
  @spec list_customers(Scope.t(), keyword()) ::
          {:ok, [Customer.t()]} | {:error, :unauthorized}
  def list_customers(%Scope{} = scope, opts \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      limit = opts |> Keyword.get(:limit, @list_cap) |> min(@list_cap)

      {:ok,
       Repo.all(
         from c in Customer,
           where: c.team_id == ^Scope.team_id!(scope),
           order_by: [asc: c.external_id],
           limit: ^limit
       )}
    end
  end

  @doc "Number of customers in the scope's team."
  @spec count_customers(Scope.t()) :: {:ok, non_neg_integer()} | {:error, :unauthorized}
  def count_customers(%Scope{} = scope) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.aggregate(
         from(c in Customer, where: c.team_id == ^Scope.team_id!(scope)),
         :count
       )}
    end
  end

  @doc "Immutable version history of a customer, oldest first."
  @spec list_customer_versions(Scope.t(), Customer.t()) ::
          {:ok, [CustomerVersion.t()]} | {:error, :unauthorized}
  def list_customer_versions(%Scope{} = scope, %Customer{} = customer) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.all(
         from v in CustomerVersion,
           where: v.team_id == ^Scope.team_id!(scope) and v.customer_id == ^customer.id,
           order_by: [asc: v.version]
       )}
    end
  end

  @doc """
  Connects a customer to an ERP customer number (BC-US-031). The mapping is
  stored `pending` until adapter validation confirms it; only `invalid`
  mappings block synchronization (INV-011). Requires `finance_operator`.
  """
  @spec upsert_customer_erp_mapping(Scope.t(), Customer.t(), map()) ::
          {:ok, CustomerErpMapping.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def upsert_customer_erp_mapping(%Scope{} = scope, %Customer{} = customer, attrs) do
    with :ok <- authorize(scope, [:finance_operator, :team_admin]),
         :ok <- ensure_same_team(scope, customer.team_id) do
      team_id = Scope.team_id!(scope)
      erp_connection_id = Map.fetch!(attrs, :erp_connection_id)
      number = Map.fetch!(attrs, :external_customer_number)

      Repo.transaction(fn ->
        existing =
          Repo.one(
            from m in CustomerErpMapping,
              where:
                m.team_id == ^team_id and m.customer_id == ^customer.id and
                  m.erp_connection_id == ^erp_connection_id
          )

        mapping =
          case existing do
            nil ->
              Repo.insert!(%CustomerErpMapping{
                team_id: team_id,
                customer_id: customer.id,
                erp_connection_id: erp_connection_id,
                external_customer_number: number,
                validation_status: Map.get(attrs, :validation_status, "pending")
              })

            %CustomerErpMapping{} = mapping ->
              mapping
              |> Ecto.Changeset.change(
                external_customer_number: number,
                validation_status: Map.get(attrs, :validation_status, "pending")
              )
              |> Repo.update!()
          end

        Audit.record!(scope, "contracts.customer.erp_mapping_upserted",
          aggregate: {:customer, customer.id},
          payload: %{external_customer_number: number}
        )

        mapping
      end)
    end
  end

  @doc "ERP mappings of a customer, oldest first (read roles)."
  @spec list_customer_erp_mappings(Scope.t(), Customer.t()) ::
          {:ok, [CustomerErpMapping.t()]} | {:error, :unauthorized}
  def list_customer_erp_mappings(%Scope{} = scope, %Customer{} = customer) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.all(
         from m in CustomerErpMapping,
           where: m.team_id == ^Scope.team_id!(scope) and m.customer_id == ^customer.id,
           order_by: [asc: m.created_at]
       )}
    end
  end

  ## Contracts (BC-US-033)

  @doc """
  Creates a contract for a customer of the scope's team, together with its
  immutable version 1 (pinning the customer's current version).

  `attrs`: `:customer_id`, `:external_reference`, `:currency`, `:start_date`
  (required), `:end_date_exclusive`, `:status` (`:draft`/`:active`),
  `:metadata` (optional).
  """
  @spec create_contract(Scope.t(), map() | keyword()) ::
          {:ok, Contract.t()}
          | {:error, :unauthorized | :customer_not_found | Ecto.Changeset.t()}
  def create_contract(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        customer =
          case fetch_team_row(Customer, team_id, attrs[:customer_id]) do
            {:ok, customer} -> customer
            {:error, :not_found} -> Repo.rollback(:customer_not_found)
          end

        changeset =
          Contract.create_changeset(
            %Contract{team_id: team_id, customer_id: customer.id, current_version: 1},
            attrs
          )

        contract =
          case Repo.insert(changeset) do
            {:ok, contract} -> contract
            {:error, changeset} -> Repo.rollback(changeset)
          end

        version_snapshot = %{
          "customer_id" => customer.id,
          "customer_version" => customer.current_version,
          "currency" => contract.currency,
          "effective_start" => contract.start_date,
          "effective_end_exclusive" => contract.end_date_exclusive,
          "external_reference" => contract.external_reference,
          "metadata" => attrs[:metadata] || %{}
        }

        Repo.insert!(%ContractVersion{
          team_id: team_id,
          contract_id: contract.id,
          version: 1,
          customer_version: customer.current_version,
          currency: contract.currency,
          effective_start: contract.start_date,
          effective_end_exclusive: contract.end_date_exclusive,
          metadata: attrs[:metadata] || %{},
          content_hash: Canonical.hash(version_snapshot)
        })

        Audit.record!(scope, "contracts.contract.created",
          aggregate: {"contract", contract.id},
          payload: %{external_reference: contract.external_reference, customer_id: customer.id}
        )

        contract
      end)
    end
  end

  @doc "Fetches a contract of the scope's team."
  @spec get_contract(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Contract.t()} | {:error, :unauthorized | :not_found}
  def get_contract(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      fetch_team_row(Contract, Scope.team_id!(scope), id)
    end
  end

  @doc """
  Lists the team's contracts ordered by external reference (capped at
  #{@list_cap}). Options: `:customer_id` filters to one customer's contracts.
  """
  @spec list_contracts(Scope.t(), keyword()) ::
          {:ok, [Contract.t()]} | {:error, :unauthorized}
  def list_contracts(%Scope{} = scope, opts \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      limit = opts |> Keyword.get(:limit, @list_cap) |> min(@list_cap)

      query =
        from c in Contract,
          where: c.team_id == ^Scope.team_id!(scope),
          order_by: [asc: c.external_reference],
          limit: ^limit

      query =
        case Keyword.get(opts, :customer_id) do
          nil -> query
          customer_id -> where(query, [c], c.customer_id == ^customer_id)
        end

      {:ok, Repo.all(query)}
    end
  end

  ## Subscriptions (BC-US-034…039)

  @doc """
  Starts a subscription on a contract of the scope's team (BC-US-034/035).

  `attrs`: `:external_id`, `:contract_id`, `:plan_version_id`, `:quantity`,
  `:start_date` (required), `:end_date_exclusive`, `:billing_anchor_day`
  (defaults to the start date's day), `:time_zone` (defaults to the team's),
  `:price_overrides`, `:cancellation_policy`, `:idempotency_key`.

  The subscription period must fall inside the contract dates
  (`{:error, :outside_contract_period}`). Status is `:scheduled` when the
  start date is after today in the subscription's time zone, `:active`
  otherwise. Idempotent by `(team, external_id)`: an identical canonical
  replay returns the existing subscription, a different payload is
  `{:error, :conflict}`.
  """
  @spec start_subscription(Scope.t(), map() | keyword()) ::
          {:ok, Subscription.t()}
          | {:error,
             :unauthorized
             | :contract_not_found
             | :outside_contract_period
             | :conflict
             | Ecto.Changeset.t()}
  def start_subscription(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        contract =
          case fetch_team_row(Contract, team_id, attrs[:contract_id]) do
            {:ok, contract} -> contract
            {:error, :not_found} -> Repo.rollback(:contract_not_found)
          end

        time_zone = attrs[:time_zone] || team_time_zone(scope)
        policy = attrs[:cancellation_policy] || "end_of_period"
        overrides = attrs[:price_overrides] || %{}
        quantity = to_decimal(attrs[:quantity])

        base_changeset =
          Subscription.create_changeset(
            %Subscription{
              team_id: team_id,
              contract_id: contract.id,
              current_version: 1,
              version: 1
            },
            %{
              external_id: attrs[:external_id],
              start_date: attrs[:start_date],
              end_date_exclusive: attrs[:end_date_exclusive],
              billing_anchor_day: attrs[:billing_anchor_day],
              time_zone: time_zone
            }
          )

        case Ecto.Changeset.apply_action(base_changeset, :insert) do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end

        external_id = Ecto.Changeset.get_field(base_changeset, :external_id)
        start_date = Ecto.Changeset.get_field(base_changeset, :start_date)
        end_date = Ecto.Changeset.get_field(base_changeset, :end_date_exclusive)

        anchor =
          Ecto.Changeset.get_field(base_changeset, :billing_anchor_day) || start_date.day

        payload =
          stored_payload(%{
            "external_id" => external_id,
            "contract_id" => contract.id,
            "plan_version_id" => attrs[:plan_version_id],
            "quantity" => quantity,
            "start_date" => start_date,
            "end_date_exclusive" => end_date,
            "billing_anchor_day" => anchor,
            "time_zone" => time_zone,
            "price_overrides" => overrides,
            "cancellation_policy" => policy
          })

        case Repo.get_by(Subscription, team_id: team_id, external_id: external_id) do
          %Subscription{} = existing ->
            original =
              Repo.get_by(SubscriptionChange,
                team_id: team_id,
                subscription_id: existing.id,
                change_type: :start
              )

            if original && Canonical.hash(original.payload) == Canonical.hash(payload) do
              existing
            else
              Repo.rollback(:conflict)
            end

          nil ->
            unless inside_contract?(contract, start_date, end_date) do
              Repo.rollback(:outside_contract_period)
            end

            status =
              if Date.after?(start_date, local_today(time_zone)), do: :scheduled, else: :active

            subscription =
              base_changeset
              |> Ecto.Changeset.put_change(:status, status)
              |> Ecto.Changeset.put_change(:billing_anchor_day, anchor)
              |> Repo.insert!()

            insert_subscription_version!(subscription, 1, %{
              plan_version_id: attrs[:plan_version_id],
              quantity: attrs[:quantity],
              effective_start: start_date,
              effective_end_exclusive: end_date,
              price_overrides: overrides,
              cancellation_policy: policy
            })

            Repo.insert!(%SubscriptionChange{
              team_id: team_id,
              subscription_id: subscription.id,
              change_type: :start,
              effective_date: start_date,
              idempotency_key: attrs[:idempotency_key] || "start:#{external_id}",
              actor_reference: actor_reference(scope),
              payload: payload,
              result: %{
                "subscription_id" => subscription.id,
                "status" => to_string(status),
                "version" => 1
              }
            })

            Audit.record!(scope, "contracts.subscription.started",
              aggregate: {"subscription", subscription.id},
              payload: %{external_id: external_id, status: status, contract_id: contract.id}
            )

            Outbox.emit!("subscription.started.v1",
              aggregate: {"subscription", subscription.id},
              team_id: team_id,
              aggregate_version: 1,
              correlation_id: scope.correlation_id,
              payload: %{
                external_id: external_id,
                contract_id: contract.id,
                plan_version_id: attrs[:plan_version_id],
                quantity: quantity && Canonical.decimal_string(quantity),
                start_date: Date.to_iso8601(start_date),
                status: status
              }
            )

            subscription
        end
      end)
    end
  end

  @doc "Fetches a subscription of the scope's team."
  @spec get_subscription(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Subscription.t()} | {:error, :unauthorized | :not_found}
  def get_subscription(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      fetch_team_row(Subscription, Scope.team_id!(scope), id)
    end
  end

  @doc "Fetches a subscription of the scope's team by its external ID."
  @spec get_subscription_by_external_id(Scope.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, :unauthorized | :not_found}
  def get_subscription_by_external_id(%Scope{} = scope, external_id)
      when is_binary(external_id) do
    with :ok <- authorize(scope, @read_roles) do
      case Repo.get_by(Subscription,
             team_id: Scope.team_id!(scope),
             external_id: external_id
           ) do
        nil -> {:error, :not_found}
        subscription -> {:ok, subscription}
      end
    end
  end

  @doc """
  Lists the team's subscriptions ordered by external ID (capped at
  #{@list_cap}). Options: `:contract_id` filters to one contract,
  `:status` to one lifecycle status.
  """
  @spec list_subscriptions(Scope.t(), keyword()) ::
          {:ok, [Subscription.t()]} | {:error, :unauthorized}
  def list_subscriptions(%Scope{} = scope, opts \\ []) do
    with :ok <- authorize(scope, @read_roles) do
      limit = opts |> Keyword.get(:limit, @list_cap) |> min(@list_cap)

      query =
        from s in Subscription,
          where: s.team_id == ^Scope.team_id!(scope),
          order_by: [asc: s.external_id],
          limit: ^limit

      query =
        case Keyword.get(opts, :contract_id) do
          nil -> query
          contract_id -> where(query, [s], s.contract_id == ^contract_id)
        end

      query =
        case Keyword.get(opts, :status) do
          nil -> query
          status -> where(query, [s], s.status == ^status)
        end

      {:ok, Repo.all(query)}
    end
  end

  @doc "Number of the team's subscriptions in `status` (default `:active`)."
  @spec count_subscriptions(Scope.t(), atom()) ::
          {:ok, non_neg_integer()} | {:error, :unauthorized}
  def count_subscriptions(%Scope{} = scope, status \\ :active) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.aggregate(
         from(s in Subscription,
           where: s.team_id == ^Scope.team_id!(scope) and s.status == ^status
         ),
         :count
       )}
    end
  end

  @doc "Version timeline of a subscription, oldest first."
  @spec list_subscription_versions(Scope.t(), Subscription.t()) ::
          {:ok, [SubscriptionVersion.t()]} | {:error, :unauthorized}
  def list_subscription_versions(%Scope{} = scope, %Subscription{} = subscription) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.all(
         from v in SubscriptionVersion,
           where: v.team_id == ^Scope.team_id!(scope) and v.subscription_id == ^subscription.id,
           order_by: [asc: v.version]
       )}
    end
  end

  @doc "Append-only command history of a subscription, oldest first."
  @spec list_subscription_changes(Scope.t(), Subscription.t()) ::
          {:ok, [SubscriptionChange.t()]} | {:error, :unauthorized}
  def list_subscription_changes(%Scope{} = scope, %Subscription{} = subscription) do
    with :ok <- authorize(scope, @read_roles) do
      {:ok,
       Repo.all(
         from c in SubscriptionChange,
           where: c.team_id == ^Scope.team_id!(scope) and c.subscription_id == ^subscription.id,
           order_by: [asc: c.created_at]
       )}
    end
  end

  @doc """
  Changes the quantity of an active subscription (BC-US-036).

  `attrs`: `:quantity` (required), `:effective_date` (`:immediate`/omitted →
  today in the subscription's time zone, or an explicit `Date`),
  `:idempotency_key`. Closes the current version at the effective date and
  appends the successor with the new quantity; an effective date before the
  current version's start is `{:error, :effective_date_in_past}`.
  """
  @spec change_quantity(Scope.t(), Subscription.t(), map() | keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def change_quantity(%Scope{} = scope, %Subscription{} = subscription, attrs) do
    version_change(scope, subscription, Map.new(attrs), :quantity_change)
  end

  @doc """
  Moves an active subscription to another plan version (BC-US-037) using the
  same version-splitting mechanics as `change_quantity/3`.

  `attrs`: `:plan_version_id` (required), `:quantity` (defaults to the
  current version's), `:effective_date`, `:idempotency_key`.
  """
  @spec change_plan_version(Scope.t(), Subscription.t(), map() | keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def change_plan_version(%Scope{} = scope, %Subscription{} = subscription, attrs) do
    version_change(scope, subscription, Map.new(attrs), :plan_change)
  end

  @doc """
  Cancels a subscription (BC-US-038) per the §11.1 machine.

  `attrs`: `:mode` (`:immediate` or `:end_of_period`), `:reason`,
  `:idempotency_key`; `:effective_date` for immediate (defaults to today in
  the subscription's time zone); `:period_end_date` (required for
  `:end_of_period` — period math belongs to billing, the boundary is passed
  in explicitly).

  Immediate: `cancelled` with `end_date_exclusive` at the effective date
  (a scheduled subscription is cancelled before start and keeps no end
  date). End of period: `pending_cancellation` with `end_date_exclusive` at
  the period end; `finalize_due_cancellations/1` completes the transition at
  the boundary.
  """
  @spec cancel_subscription(Scope.t(), Subscription.t(), map() | keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def cancel_subscription(%Scope{} = scope, %Subscription{} = subscription, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        sub =
          lock_subscription(team_id, subscription.id) || Repo.rollback(:subscription_not_found)

        mode = attrs[:mode]

        unless mode in [:immediate, :end_of_period], do: Repo.rollback(:invalid_mode)

        reason = attrs[:reason]
        current = current_version!(sub)

        {event, effective_date} =
          case mode do
            :immediate ->
              {:cancel, resolve_effective_date(attrs[:effective_date], sub.time_zone)}

            :end_of_period ->
              case attrs[:period_end_date] do
                %Date{} = period_end -> {:cancel_at_period_end, period_end}
                _missing -> Repo.rollback(:missing_period_end_date)
              end
          end

        payload =
          stored_payload(%{
            "change_type" => "cancel",
            "mode" => mode,
            "effective_date" => effective_date,
            "reason" => reason
          })

        key = attrs[:idempotency_key] || Ecto.UUID.generate()

        case replayed_change(team_id, sub.id, key) do
          %SubscriptionChange{} = original ->
            replay_or_conflict(original, payload, sub)

          nil ->
            next_status =
              case StateMachine.transition(@subscription_machine, sub.status, event) do
                {:ok, next_status} -> next_status
                {:error, _} -> Repo.rollback(:invalid_state)
              end

            version_end =
              cond do
                sub.status == :scheduled ->
                  # Cancelled before start: the version never becomes effective.
                  current.effective_start

                Date.before?(effective_date, current.effective_start) ->
                  Repo.rollback(:effective_date_in_past)

                current.effective_end_exclusive != nil and
                    Date.after?(effective_date, current.effective_end_exclusive) ->
                  Repo.rollback(:effective_date_after_end)

                true ->
                  effective_date
              end

            current
            |> Ecto.Changeset.change(effective_end_exclusive: version_end, status_reason: reason)
            |> Repo.update!()

            end_date_exclusive =
              if sub.status == :scheduled do
                nil
              else
                unless Date.after?(effective_date, sub.start_date) do
                  Repo.rollback(:effective_date_in_past)
                end

                effective_date
              end

            updated =
              sub
              |> Ecto.Changeset.change(
                status: next_status,
                end_date_exclusive: end_date_exclusive,
                version: sub.version + 1
              )
              |> Repo.update!()

            Repo.insert!(%SubscriptionChange{
              team_id: team_id,
              subscription_id: sub.id,
              change_type: :cancel,
              effective_date: effective_date,
              idempotency_key: key,
              actor_reference: actor_reference(scope),
              payload: payload,
              result: %{"status" => to_string(next_status)}
            })

            Audit.record!(scope, "contracts.subscription.cancelled",
              aggregate: {"subscription", sub.id},
              payload: %{
                mode: mode,
                effective_date: Date.to_iso8601(effective_date),
                reason: reason,
                status: next_status
              }
            )

            Outbox.emit!("subscription.cancelled.v1",
              aggregate: {"subscription", sub.id},
              team_id: team_id,
              aggregate_version: sub.current_version,
              correlation_id: scope.correlation_id,
              payload: %{
                external_id: sub.external_id,
                mode: mode,
                effective_date: Date.to_iso8601(effective_date),
                reason: reason,
                status: next_status
              }
            )

            updated
        end
      end)
    end
  end

  @doc "Pauses an active subscription (§11.1, BC-US-039)."
  @spec pause_subscription(Scope.t(), Subscription.t(), map() | keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def pause_subscription(%Scope{} = scope, %Subscription{} = subscription, attrs \\ %{}) do
    status_change(scope, subscription, Map.new(attrs), :pause)
  end

  @doc "Resumes a paused subscription (§11.1, BC-US-039)."
  @spec resume_subscription(Scope.t(), Subscription.t(), map() | keyword()) ::
          {:ok, Subscription.t()} | {:error, term()}
  def resume_subscription(%Scope{} = scope, %Subscription{} = subscription, attrs \\ %{}) do
    status_change(scope, subscription, Map.new(attrs), :resume)
  end

  @doc """
  Promotes scheduled subscriptions whose start date has been reached
  (BC-US-035); called by the scheduler. Audited as `:system`; emits
  `subscription.changed.v1` with an `activated` payload per subscription.
  Returns the number of activated subscriptions.
  """
  @spec activate_due_subscriptions(Date.t()) :: non_neg_integer()
  def activate_due_subscriptions(%Date{} = today) do
    system_status_sweep(
      from(s in Subscription,
        where: s.status == :scheduled and s.start_date <= ^today,
        lock: "FOR UPDATE SKIP LOCKED"
      ),
      :activate,
      "activated"
    )
  end

  @doc """
  Completes `pending_cancellation → cancelled` for subscriptions whose end
  date boundary has been reached (§11.1); called by the scheduler. Audited
  as `:system`; emits `subscription.changed.v1` with a
  `cancellation_finalized` payload. Returns the number of finalized
  subscriptions.
  """
  @spec finalize_due_cancellations(Date.t()) :: non_neg_integer()
  def finalize_due_cancellations(%Date{} = today) do
    system_status_sweep(
      from(s in Subscription,
        where:
          s.status == :pending_cancellation and not is_nil(s.end_date_exclusive) and
            s.end_date_exclusive <= ^today,
        lock: "FOR UPDATE SKIP LOCKED"
      ),
      :reach_period_boundary,
      "cancellation_finalized"
    )
  end

  ## Charge instances (BC-US-041)

  @doc """
  Creates an idempotent one-time charge instance against a contract (and
  optionally one of its subscriptions).

  `attrs`: `:external_id`, `:contract_id`, `:product_id`, `:product_version`,
  `:eligible_on`, `:recognition_mode` (required); exactly one pricing source —
  `:price_component_id` with `:quantity` > 0, or a non-negative
  `:amount_minor` (then quantity is fixed at 1); `:currency` must match the
  contract (defaults to it); `:over_time` requires the half-open
  `:service_start`/`:service_end_exclusive` period, `:point_in_time` forbids
  it.

  Replays by `(team, external_id)`: an identical canonical payload returns
  the original charge, a different payload is `{:error, :conflict}`.
  """
  @spec create_charge_instance(Scope.t(), map() | keyword()) ::
          {:ok, ChargeInstance.t()} | {:error, term()}
  def create_charge_instance(%Scope{} = scope, attrs) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        contract =
          case fetch_team_row(Contract, team_id, attrs[:contract_id]) do
            {:ok, contract} -> contract
            {:error, :not_found} -> Repo.rollback(:contract_not_found)
          end

        subscription_id = resolve_charge_subscription(team_id, contract, attrs[:subscription_id])
        {price_component_id, amount_minor, quantity} = resolve_pricing_source(attrs)

        currency =
          case attrs[:currency] do
            nil -> contract.currency
            currency when currency == contract.currency -> currency
            _mismatch -> Repo.rollback(:currency_mismatch)
          end

        payload = %{
          "external_id" => attrs[:external_id],
          "contract_id" => contract.id,
          "subscription_id" => subscription_id,
          "product_id" => attrs[:product_id],
          "product_version" => attrs[:product_version],
          "price_component_id" => price_component_id,
          "amount_minor" => amount_minor,
          "quantity" => quantity,
          "currency" => currency,
          "eligible_on" => attrs[:eligible_on],
          "recognition_mode" => attrs[:recognition_mode],
          "service_start" => attrs[:service_start],
          "service_end_exclusive" => attrs[:service_end_exclusive]
        }

        payload_hash = Canonical.hash(payload)

        existing =
          if is_binary(attrs[:external_id]) do
            Repo.get_by(ChargeInstance, team_id: team_id, external_id: attrs[:external_id])
          end

        case existing do
          %ChargeInstance{} = original ->
            if original.payload_hash == payload_hash do
              original
            else
              Repo.rollback(:conflict)
            end

          nil ->
            changeset =
              ChargeInstance.create_changeset(
                %ChargeInstance{
                  team_id: team_id,
                  contract_id: contract.id,
                  subscription_id: subscription_id,
                  status: :pending,
                  canonical_payload: stored_payload(payload),
                  payload_hash: payload_hash
                },
                %{
                  external_id: attrs[:external_id],
                  product_id: attrs[:product_id],
                  product_version: attrs[:product_version],
                  price_component_id: price_component_id,
                  eligible_on: attrs[:eligible_on],
                  quantity: quantity,
                  amount_minor: amount_minor,
                  currency: currency,
                  recognition_mode: attrs[:recognition_mode],
                  service_start: attrs[:service_start],
                  service_end_exclusive: attrs[:service_end_exclusive]
                }
              )

            charge =
              case Repo.insert(changeset) do
                {:ok, charge} -> charge
                {:error, changeset} -> Repo.rollback(changeset)
              end

            Audit.record!(scope, "contracts.charge_instance.created",
              aggregate: {"charge_instance", charge.id},
              payload: %{
                external_id: charge.external_id,
                contract_id: contract.id,
                payload_hash: payload_hash
              }
            )

            Outbox.emit!("charge_instance.created.v1",
              aggregate: {"charge_instance", charge.id},
              team_id: team_id,
              correlation_id: scope.correlation_id,
              payload: %{
                external_id: charge.external_id,
                contract_id: contract.id,
                subscription_id: subscription_id,
                eligible_on: to_string(charge.eligible_on),
                recognition_mode: charge.recognition_mode
              }
            )

            charge
        end
      end)
    end
  end

  @doc "Fetches a charge instance of the scope's team."
  @spec get_charge_instance(Scope.t(), Ecto.UUID.t()) ::
          {:ok, ChargeInstance.t()} | {:error, :unauthorized | :not_found}
  def get_charge_instance(%Scope{} = scope, id) do
    with :ok <- authorize(scope, @read_roles) do
      fetch_team_row(ChargeInstance, Scope.team_id!(scope), id)
    end
  end

  @doc """
  Cancels a charge instance — permitted only while it is `pending`, i.e.
  before it is frozen into invoice intent (BC-US-041);
  `{:error, :not_pending}` otherwise.
  """
  @spec cancel_charge_instance(Scope.t(), ChargeInstance.t(), map() | keyword()) ::
          {:ok, ChargeInstance.t()} | {:error, term()}
  def cancel_charge_instance(%Scope{} = scope, %ChargeInstance{} = charge, attrs \\ %{}) do
    attrs = Map.new(attrs)

    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        charge =
          Repo.one(
            from c in ChargeInstance,
              where: c.id == ^charge.id and c.team_id == ^team_id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:charge_instance_not_found)

        unless charge.status == :pending, do: Repo.rollback(:not_pending)

        cancelled =
          charge
          |> Ecto.Changeset.change(status: :cancelled)
          |> Repo.update!()

        Audit.record!(scope, "contracts.charge_instance.cancelled",
          aggregate: {"charge_instance", charge.id},
          payload: %{external_id: charge.external_id, reason: attrs[:reason]}
        )

        Outbox.emit!("charge_instance.cancelled.v1",
          aggregate: {"charge_instance", charge.id},
          team_id: team_id,
          correlation_id: scope.correlation_id,
          payload: %{external_id: charge.external_id, reason: attrs[:reason]}
        )

        cancelled
      end)
    end
  end

  ## Customer internals

  defp insert_customer(scope, team_id, attrs) do
    status = attrs[:status] || :active
    snapshot = customer_snapshot(attrs, status)

    customer_changeset =
      Customer.create_changeset(
        %Customer{team_id: team_id, current_version: 1},
        Map.put(attrs, :status, status)
      )

    customer =
      case Repo.insert(customer_changeset) do
        {:ok, customer} -> customer
        {:error, changeset} -> Repo.rollback(changeset)
      end

    version = insert_customer_version(scope, customer, attrs, snapshot, 1)
    %{customer: customer, version: version}
  end

  defp update_customer(scope, customer, attrs) do
    status = attrs[:status] || customer.status
    snapshot = customer_snapshot(attrs, status)

    current =
      Repo.one!(
        from v in CustomerVersion,
          where: v.customer_id == ^customer.id and v.version == ^customer.current_version
      )

    if current.content_hash == Canonical.hash(snapshot) do
      # Idempotent no-op: the canonical snapshot is unchanged.
      %{customer: customer, version: nil}
    else
      next = customer.current_version + 1

      customer =
        case customer
             |> Customer.update_changeset(%{status: status})
             |> Ecto.Changeset.change(current_version: next)
             |> Repo.update() do
          {:ok, customer} -> customer
          {:error, changeset} -> Repo.rollback(changeset)
        end

      version = insert_customer_version(scope, customer, attrs, snapshot, next)
      %{customer: customer, version: version}
    end
  end

  defp insert_customer_version(scope, customer, attrs, snapshot, version_number) do
    changeset =
      CustomerVersion.changeset(
        %CustomerVersion{
          team_id: customer.team_id,
          customer_id: customer.id,
          version: version_number,
          snapshot: snapshot,
          content_hash: Canonical.hash(snapshot)
        },
        attrs
      )

    version =
      case Repo.insert(changeset) do
        {:ok, version} -> version
        {:error, changeset} -> Repo.rollback(changeset)
      end

    Audit.record!(scope, "contracts.customer.version_created",
      aggregate: {"customer", customer.id},
      payload: %{
        external_id: customer.external_id,
        version: version_number,
        content_hash: version.content_hash
      }
    )

    Outbox.emit!("customer.version_created.v1",
      aggregate: {"customer", customer.id},
      team_id: customer.team_id,
      aggregate_version: version_number,
      correlation_id: scope.correlation_id,
      payload: %{
        external_id: customer.external_id,
        version: version_number,
        content_hash: version.content_hash
      }
    )

    version
  end

  defp customer_snapshot(attrs, status) do
    %{
      "legal_name" => attrs[:legal_name],
      "address_line" => attrs[:address_line],
      "zip" => attrs[:zip],
      "city" => attrs[:city],
      "country" => attrs[:country],
      "email" => attrs[:email],
      "vat_number" => attrs[:vat_number],
      "currency_preference" => attrs[:currency_preference],
      "status" => to_string(status)
    }
  end

  defp lock_customer(team_id, external_id) when is_binary(external_id) do
    Repo.one(
      from c in Customer,
        where: c.team_id == ^team_id and c.external_id == ^external_id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_customer(_team_id, _external_id), do: nil

  ## Subscription internals

  defp version_change(scope, subscription, attrs, change_type) do
    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        sub =
          lock_subscription(team_id, subscription.id) || Repo.rollback(:subscription_not_found)

        current = current_version!(sub)
        effective_date = resolve_effective_date(attrs[:effective_date], sub.time_zone)

        {plan_version_id, quantity} =
          case change_type do
            :quantity_change ->
              quantity = to_decimal(attrs[:quantity]) || Repo.rollback(:invalid_quantity)
              {current.plan_version_id, quantity}

            :plan_change ->
              plan_version_id = attrs[:plan_version_id] || Repo.rollback(:missing_plan_version)
              {plan_version_id, to_decimal(attrs[:quantity]) || current.quantity}
          end

        payload =
          stored_payload(%{
            "change_type" => change_type,
            "effective_date" => effective_date,
            "plan_version_id" => plan_version_id,
            "quantity" => quantity
          })

        key = attrs[:idempotency_key] || Ecto.UUID.generate()

        case replayed_change(team_id, sub.id, key) do
          %SubscriptionChange{} = original ->
            replay_or_conflict(original, payload, sub)

          nil ->
            case StateMachine.transition(@subscription_machine, sub.status, :change) do
              {:ok, :active} -> :ok
              {:error, _} -> Repo.rollback(:invalid_state)
            end

            cond do
              Date.before?(effective_date, current.effective_start) ->
                Repo.rollback(:effective_date_in_past)

              current.effective_end_exclusive != nil and
                  not Date.before?(effective_date, current.effective_end_exclusive) ->
                Repo.rollback(:effective_date_after_end)

              true ->
                :ok
            end

            # Close the current version at the effective date, then append the
            # successor — order matters: the exclusion constraint is checked
            # per statement.
            current
            |> Ecto.Changeset.change(effective_end_exclusive: effective_date)
            |> Repo.update!()

            next = sub.current_version + 1

            insert_subscription_version!(sub, next, %{
              plan_version_id: plan_version_id,
              quantity: quantity,
              effective_start: effective_date,
              effective_end_exclusive: current.effective_end_exclusive,
              price_overrides: current.price_overrides,
              cancellation_policy: current.cancellation_policy
            })

            updated =
              sub
              |> Ecto.Changeset.change(current_version: next, version: sub.version + 1)
              |> Repo.update!()

            Repo.insert!(%SubscriptionChange{
              team_id: team_id,
              subscription_id: sub.id,
              change_type: change_type,
              effective_date: effective_date,
              idempotency_key: key,
              actor_reference: actor_reference(scope),
              payload: payload,
              result: %{"from_version" => sub.current_version, "to_version" => next}
            })

            Audit.record!(scope, "contracts.subscription.#{audit_suffix(change_type)}",
              aggregate: {"subscription", sub.id},
              payload: %{
                effective_date: Date.to_iso8601(effective_date),
                from_version: sub.current_version,
                to_version: next
              }
            )

            Outbox.emit!("subscription.changed.v1",
              aggregate: {"subscription", sub.id},
              team_id: team_id,
              aggregate_version: next,
              correlation_id: scope.correlation_id,
              payload: %{
                change: change_type,
                external_id: sub.external_id,
                effective_date: Date.to_iso8601(effective_date),
                plan_version_id: plan_version_id,
                quantity: Canonical.decimal_string(quantity),
                from_version: sub.current_version,
                to_version: next
              }
            )

            updated
        end
      end)
    end
  end

  defp status_change(scope, subscription, attrs, event) when event in [:pause, :resume] do
    with :ok <- authorize(scope, @write_roles) do
      team_id = Scope.team_id!(scope)

      Repo.transaction(fn ->
        sub =
          lock_subscription(team_id, subscription.id) || Repo.rollback(:subscription_not_found)

        effective_date = resolve_effective_date(attrs[:effective_date], sub.time_zone)

        payload =
          stored_payload(%{
            "change_type" => event,
            "effective_date" => effective_date,
            "reason" => attrs[:reason]
          })

        key = attrs[:idempotency_key] || Ecto.UUID.generate()

        case replayed_change(team_id, sub.id, key) do
          %SubscriptionChange{} = original ->
            replay_or_conflict(original, payload, sub)

          nil ->
            next_status =
              case StateMachine.transition(@subscription_machine, sub.status, event) do
                {:ok, next_status} -> next_status
                {:error, _} -> Repo.rollback(:invalid_state)
              end

            updated =
              sub
              |> Ecto.Changeset.change(status: next_status, version: sub.version + 1)
              |> Repo.update!()

            Repo.insert!(%SubscriptionChange{
              team_id: team_id,
              subscription_id: sub.id,
              change_type: event,
              effective_date: effective_date,
              idempotency_key: key,
              actor_reference: actor_reference(scope),
              payload: payload,
              result: %{"status" => to_string(next_status)}
            })

            Audit.record!(scope, "contracts.subscription.#{event}d",
              aggregate: {"subscription", sub.id},
              payload: %{effective_date: Date.to_iso8601(effective_date), reason: attrs[:reason]}
            )

            Outbox.emit!("subscription.changed.v1",
              aggregate: {"subscription", sub.id},
              team_id: team_id,
              aggregate_version: sub.current_version,
              correlation_id: scope.correlation_id,
              payload: %{
                change: event,
                external_id: sub.external_id,
                effective_date: Date.to_iso8601(effective_date),
                reason: attrs[:reason]
              }
            )

            updated
        end
      end)
    end
  end

  defp system_status_sweep(query, event, change_label) do
    {:ok, count} =
      Repo.transaction(fn ->
        due = Repo.all(query)

        for sub <- due do
          next_status =
            case StateMachine.transition(@subscription_machine, sub.status, event) do
              {:ok, next_status} -> next_status
              {:error, error} -> raise "illegal system transition: #{inspect(error)}"
            end

          sub
          |> Ecto.Changeset.change(status: next_status, version: sub.version + 1)
          |> Repo.update!()

          Audit.record!(:system, "contracts.subscription.#{change_label}",
            aggregate: {"subscription", sub.id},
            team_id: sub.team_id,
            payload: %{external_id: sub.external_id, status: next_status}
          )

          Outbox.emit!("subscription.changed.v1",
            aggregate: {"subscription", sub.id},
            team_id: sub.team_id,
            aggregate_version: sub.current_version,
            payload: %{change: change_label, external_id: sub.external_id, status: next_status}
          )
        end

        length(due)
      end)

    count
  end

  defp insert_subscription_version!(sub, version_number, attrs) do
    changeset =
      SubscriptionVersion.changeset(
        %SubscriptionVersion{
          team_id: sub.team_id,
          subscription_id: sub.id,
          version: version_number
        },
        attrs
      )

    case Repo.insert(changeset) do
      {:ok, version} -> version
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp lock_subscription(team_id, id) do
    Repo.one(
      from s in Subscription,
        where: s.id == ^id and s.team_id == ^team_id,
        lock: "FOR UPDATE"
    )
  end

  defp current_version!(sub) do
    Repo.one!(
      from v in SubscriptionVersion,
        where: v.subscription_id == ^sub.id and v.version == ^sub.current_version
    )
  end

  defp replayed_change(team_id, subscription_id, idempotency_key) do
    Repo.get_by(SubscriptionChange,
      team_id: team_id,
      subscription_id: subscription_id,
      idempotency_key: idempotency_key
    )
  end

  defp replay_or_conflict(%SubscriptionChange{} = original, payload, sub) do
    if Canonical.hash(original.payload) == Canonical.hash(payload) do
      sub
    else
      Repo.rollback(:conflict)
    end
  end

  defp inside_contract?(%Contract{} = contract, start_date, end_date_exclusive) do
    not Date.before?(start_date, contract.start_date) and
      (is_nil(contract.end_date_exclusive) or
         Date.before?(start_date, contract.end_date_exclusive)) and
      (is_nil(end_date_exclusive) or is_nil(contract.end_date_exclusive) or
         not Date.after?(end_date_exclusive, contract.end_date_exclusive))
  end

  defp audit_suffix(:quantity_change), do: "quantity_changed"
  defp audit_suffix(:plan_change), do: "plan_changed"

  ## Charge instance internals

  defp resolve_charge_subscription(_team_id, _contract, nil), do: nil

  defp resolve_charge_subscription(team_id, contract, subscription_id) do
    case fetch_team_row(Subscription, team_id, subscription_id) do
      {:ok, %Subscription{} = subscription} ->
        if subscription.contract_id == contract.id do
          subscription.id
        else
          Repo.rollback(:subscription_not_in_contract)
        end

      {:error, :not_found} ->
        Repo.rollback(:subscription_not_in_contract)
    end
  end

  defp resolve_pricing_source(attrs) do
    price_component_id = attrs[:price_component_id]
    amount_minor = attrs[:amount_minor]

    cond do
      not is_nil(price_component_id) and not is_nil(amount_minor) ->
        Repo.rollback(:ambiguous_pricing_source)

      is_nil(price_component_id) and is_nil(amount_minor) ->
        Repo.rollback(:missing_pricing_source)

      not is_nil(amount_minor) ->
        unless is_integer(amount_minor), do: Repo.rollback(:invalid_amount)
        if amount_minor < 0, do: Repo.rollback(:negative_amount)

        quantity = to_decimal(attrs[:quantity]) || Decimal.new(1)

        unless Decimal.eq?(quantity, Decimal.new(1)), do: Repo.rollback(:invalid_quantity)

        {nil, amount_minor, Decimal.new(1)}

      true ->
        quantity = to_decimal(attrs[:quantity]) || Repo.rollback(:invalid_quantity)

        if Decimal.compare(quantity, 0) != :gt, do: Repo.rollback(:invalid_quantity)

        {price_component_id, nil, quantity}
    end
  end

  ## Shared helpers

  defp ensure_same_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :unauthorized}
  end

  defp authorize(%Scope{} = scope, roles) do
    if Scope.team_scoped?(scope) and Scope.has_team_role?(scope, roles) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp fetch_team_row(_schema, _team_id, nil), do: {:error, :not_found}

  defp fetch_team_row(schema, team_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get_by(schema, id: uuid, team_id: team_id) do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp team_time_zone(%Scope{team: %{time_zone: time_zone}}) when is_binary(time_zone),
    do: time_zone

  defp team_time_zone(%Scope{}), do: "Etc/UTC"

  # Team-local today. Falls back to the UTC date when no time zone database
  # is configured (the default Calendar database only knows Etc/UTC).
  defp local_today(time_zone) do
    case DateTime.now(time_zone) do
      {:ok, now} -> DateTime.to_date(now)
      {:error, _} -> Date.utc_today()
    end
  end

  defp resolve_effective_date(nil, time_zone), do: local_today(time_zone)
  defp resolve_effective_date(:immediate, time_zone), do: local_today(time_zone)
  defp resolve_effective_date(%Date{} = date, _time_zone), do: date

  defp resolve_effective_date(value, _time_zone) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> Repo.rollback(:invalid_effective_date)
    end
  end

  defp resolve_effective_date(_value, _time_zone), do: Repo.rollback(:invalid_effective_date)

  defp actor_reference(%Scope{principal_type: :user, user: %{id: id}}), do: "user:#{id}"

  defp actor_reference(%Scope{principal_type: :service, service_credential: %{id: id}}),
    do: "service:#{id}"

  defp actor_reference(%Scope{}), do: "unknown"

  defp to_decimal(nil), do: nil
  defp to_decimal(%Decimal{} = decimal), do: decimal
  defp to_decimal(int) when is_integer(int), do: Decimal.new(int)

  defp to_decimal(binary) when is_binary(binary) do
    case Decimal.parse(binary) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp to_decimal(_other), do: nil

  # Canonical storage form for jsonb command payloads: encoding through the
  # canonical encoder and decoding back yields the exact map a later read
  # returns, so replay hash comparisons are stable across round-trips.
  defp stored_payload(map), do: map |> Canonical.encode!() |> Jason.decode!()
end
