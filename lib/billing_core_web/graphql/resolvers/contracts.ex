defmodule BillingCoreWeb.GraphQL.Resolvers.Contracts do
  @moduledoc """
  Customer, contract, subscription, and charge instance resolvers
  (SPEC §14.5, §14.9). Financial command families run through
  `BillingCore.Idempotency` (SPEC §14.3); replays re-resolve authorization
  (scope middleware) and re-fetch the referenced resource through the
  context, so the payload is always current and team-checked.
  """

  import Absinthe.Resolution.Helpers, only: [batch: 3]
  import Ecto.Query

  alias BillingCore.{Contracts, Idempotency, Repo, Scope}
  alias BillingCore.Contracts.{Customer, Subscription}
  alias BillingCoreWeb.GraphQL.{Authz, Errors, Pagination}

  ## Queries

  def customer(_parent, %{id: id}, %{context: %{scope: scope}}) do
    case Contracts.get_customer(scope, id) do
      {:ok, customer} -> {:ok, customer}
      {:error, :unauthorized} -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  def customers(_parent, args, %{context: %{scope: scope}}) do
    with :ok <- authorize_read(scope) do
      Customer
      |> where([c], c.team_id == ^Scope.team_id!(scope))
      |> Pagination.connection(args, :external_id)
      |> case do
        {:ok, connection} -> {:ok, connection}
        {:error, :invalid_page_size} -> page_size_error()
        {:error, :invalid_cursor} -> Errors.query_error("INVALID_CURSOR", "cursor is not valid")
      end
    end
  end

  @doc "Batched read of the current customer version's legal name (SPEC §14.7)."
  def customer_legal_name(customer, _args, _resolution) do
    batch(
      {__MODULE__, :batch_legal_names, customer.team_id},
      {customer.id, customer.current_version},
      fn results -> {:ok, Map.get(results, customer.id)} end
    )
  end

  @doc false
  def batch_legal_names(team_id, customer_version_pairs) do
    customer_ids = Enum.map(customer_version_pairs, &elem(&1, 0))

    rows =
      Repo.all(
        from v in "customer_versions",
          prefix: "billing",
          where:
            v.team_id == type(^team_id, Ecto.UUID) and
              v.customer_id in type(^customer_ids, {:array, Ecto.UUID}),
          select: {type(v.customer_id, Ecto.UUID), v.version, v.legal_name}
      )

    wanted = Map.new(customer_version_pairs)

    for {customer_id, version, legal_name} <- rows,
        wanted[customer_id] == version,
        into: %{} do
      {customer_id, legal_name}
    end
  end

  def contract(_parent, %{id: id}, %{context: %{scope: scope}}) do
    case Contracts.get_contract(scope, id) do
      {:ok, contract} -> {:ok, contract}
      {:error, :unauthorized} -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  def subscription(_parent, %{id: id}, %{context: %{scope: scope}}) do
    case Contracts.get_subscription(scope, id) do
      {:ok, subscription} -> {:ok, subscription}
      {:error, :unauthorized} -> Errors.unauthorized()
      {:error, :not_found} -> Errors.not_found()
    end
  end

  def subscriptions(_parent, args, %{context: %{scope: scope}}) do
    with :ok <- authorize_read(scope) do
      Subscription
      |> where([s], s.team_id == ^Scope.team_id!(scope))
      |> Pagination.connection(args, :external_id)
      |> case do
        {:ok, connection} -> {:ok, connection}
        {:error, :invalid_page_size} -> page_size_error()
        {:error, :invalid_cursor} -> Errors.query_error("INVALID_CURSOR", "cursor is not valid")
      end
    end
  end

  ## upsertCustomer

  def upsert_customer(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs =
      input
      |> Map.take([
        :external_id,
        :legal_name,
        :country,
        :email,
        :address_line,
        :zip,
        :city,
        :vat_number,
        :currency_preference
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case check_expected_version(scope, input) do
      {:version_conflict, expected, actual} ->
        {:ok, Errors.version_conflict(expected, actual, cmid)}

      :ok ->
        outcome =
          Idempotency.run(
            Scope.team_id!(scope),
            "upsert_customer",
            input.idempotency_key,
            Authz.principal_id(scope),
            canonical_input(input),
            fn ->
              case Contracts.upsert_customer(scope, attrs) do
                {:ok, %{customer: customer}} -> {:ok, %{"resource_reference" => customer.id}}
                {:error, reason} -> {:error, reason}
              end
            end
          )

        case resolve_outcome(outcome, scope, &Contracts.get_customer/2) do
          {:ok, customer} -> {:ok, %{customer: customer, client_mutation_id: cmid}}
          {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
        end
    end
  end

  # Optimistic concurrency (SPEC §14.3): a stale expectedVersion must fail
  # before any write. Customers upsert by external ID, so the comparison
  # reads the current head row inside the caller's team.
  defp check_expected_version(_scope, %{expected_version: nil}), do: :ok

  defp check_expected_version(_scope, input) when not is_map_key(input, :expected_version),
    do: :ok

  defp check_expected_version(scope, %{expected_version: expected, external_id: external_id}) do
    current =
      Repo.one(
        from c in Customer,
          where: c.team_id == ^Scope.team_id!(scope) and c.external_id == ^external_id,
          select: c.current_version
      )

    cond do
      is_nil(current) and expected in [0] -> :ok
      current == expected -> :ok
      true -> {:version_conflict, expected, current}
    end
  end

  ## mapCustomerToErp

  def map_customer_to_erp(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, customer} <- Contracts.get_customer(scope, input.customer_id),
         {:ok, mapping} <-
           Contracts.upsert_customer_erp_mapping(scope, customer, %{
             erp_connection_id: input.erp_connection_id,
             external_customer_number: input.external_customer_number
           }) do
      {:ok, %{mapping: mapping, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## createContract

  def create_contract(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs =
      input
      |> Map.take([
        :customer_id,
        :external_reference,
        :currency,
        :start_date,
        :end_date_exclusive
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Contracts.create_contract(scope, attrs) do
      {:ok, contract} -> {:ok, %{contract: contract, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## createSubscription (SPEC §14.9)

  def create_subscription(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs =
      %{
        external_id: input.external_id,
        contract_id: input.contract_id,
        plan_version_id: input.plan_version_id,
        quantity: input.quantity,
        start_date: input.starts_on,
        end_date_exclusive: input[:end_date_exclusive],
        billing_anchor_day: input[:billing_anchor_day],
        idempotency_key: input.idempotency_key
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "create_subscription",
        input.idempotency_key,
        Authz.principal_id(scope),
        canonical_input(input),
        fn ->
          case Contracts.start_subscription(scope, attrs) do
            {:ok, subscription} -> {:ok, %{"resource_reference" => subscription.id}}
            {:error, reason} -> {:error, reason}
          end
        end
      )

    case resolve_outcome(outcome, scope, &Contracts.get_subscription/2) do
      {:ok, subscription} -> {:ok, %{subscription: subscription, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## changeSubscription (quantity)

  def change_subscription(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    with {:ok, subscription} <- Contracts.get_subscription(scope, input.subscription_id),
         {:ok, updated} <-
           Contracts.change_quantity(scope, subscription, %{
             quantity: input.quantity,
             effective_date: input[:effective_date] || :immediate,
             idempotency_key: input.idempotency_key
           }) do
      {:ok, %{subscription: updated, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## cancelSubscription

  def cancel_subscription(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs =
      %{
        mode: input.mode,
        effective_date: input[:effective_date],
        period_end_date: input[:period_end_date],
        reason: input[:reason],
        idempotency_key: input.idempotency_key
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    with {:ok, subscription} <- Contracts.get_subscription(scope, input.subscription_id),
         {:ok, cancelled} <- Contracts.cancel_subscription(scope, subscription, attrs) do
      {:ok, %{subscription: cancelled, client_mutation_id: cmid}}
    else
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## createChargeInstance

  def create_charge_instance(_parent, %{input: input}, %{context: %{scope: scope}}) do
    cmid = input.client_mutation_id

    attrs =
      input
      |> Map.take([
        :contract_id,
        :subscription_id,
        :external_id,
        :product_id,
        :product_version,
        :eligible_on,
        :recognition_mode,
        :amount_minor,
        :price_component_id,
        :quantity,
        :currency,
        :service_start,
        :service_end_exclusive
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    outcome =
      Idempotency.run(
        Scope.team_id!(scope),
        "create_charge_instance",
        input.idempotency_key,
        Authz.principal_id(scope),
        canonical_input(input),
        fn ->
          case Contracts.create_charge_instance(scope, attrs) do
            {:ok, charge} -> {:ok, %{"resource_reference" => charge.id}}
            {:error, reason} -> {:error, reason}
          end
        end
      )

    case resolve_outcome(outcome, scope, &Contracts.get_charge_instance/2) do
      {:ok, charge} -> {:ok, %{charge_instance: charge, client_mutation_id: cmid}}
      {:error, reason} -> {:ok, Errors.business_error(reason, cmid)}
    end
  end

  ## Shared helpers

  @doc """
  Turns an idempotency outcome into the referenced resource, re-fetching
  through the authorizing context so replays return the same payload shape.
  """
  def resolve_outcome(outcome, scope, fetcher) do
    case outcome do
      {status, %{"resource_reference" => id}} when status in [:executed, :replayed] ->
        case fetcher.(scope, id) do
          {:ok, resource} -> {:ok, resource}
          {:error, reason} -> {:error, reason}
        end

      {status, _body} when status in [:executed, :replayed] ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Canonical mutation input for idempotency hashing (SPEC §14.3): the input
  object minus the request-correlation fields.
  """
  def canonical_input(input) do
    input
    |> Map.drop([:client_mutation_id, :idempotency_key])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp authorize_read(scope) do
    if Authz.can_read?(scope), do: :ok, else: Errors.unauthorized()
  end

  defp page_size_error do
    Errors.query_error(
      "INVALID_PAGE_SIZE",
      "first must be between 1 and #{Pagination.max_page_size()}"
    )
  end
end
