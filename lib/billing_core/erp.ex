defmodule BillingCore.ERP do
  @moduledoc """
  ERP connection management (SPEC Epic A BC-US-003/004, §13.3).

  Credentials live only in the secret store; the database stores an opaque
  `secret_reference` (INV: §19.5). The default secret provider resolves the
  reference from the environment; deployments may configure another provider
  module via `config :billing_core, :secret_provider`.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Outbox, Repo, Scope}
  alias BillingCore.Domain.Canonical
  alias BillingCore.ERP.Connection

  @adapters %{
    "economic" => BillingCore.ERP.Economic,
    "fake" => BillingCore.ERP.FakeERP
  }

  @doc "Creates an ERP connection storing only the secret reference (BC-US-003)."
  @spec create_connection(Scope.t(), map()) ::
          {:ok, Connection.t()} | {:error, :unauthorized | :already_exists}
  def create_connection(%Scope{} = scope, attrs) do
    with :ok <- authorize(scope, [:finance_operator, :team_admin]) do
      team_id = Scope.team_id!(scope)

      connection = %Connection{
        team_id: team_id,
        provider: Map.fetch!(attrs, :provider),
        external_agreement_id: Map.get(attrs, :external_agreement_id),
        secret_reference: Map.fetch!(attrs, :secret_reference),
        status: "unvalidated"
      }

      {:ok, result} =
        Repo.transaction(fn ->
          case Repo.insert(connection) do
            {:ok, inserted} ->
              Audit.record!(scope, "erp.connection.created",
                aggregate: {:erp_connection, inserted.id},
                payload: %{provider: inserted.provider}
              )

              {:ok, inserted}

            {:error, _changeset} ->
              {:error, :already_exists}
          end
        end)

      result
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint =~ "erp_connections_team_id_provider",
        do: {:error, :already_exists},
        else: reraise(e, __STACKTRACE__)
  end

  @doc "Team's single connection (SPEC: one ERP connection per team in v1)."
  @spec get_connection(Scope.t()) :: {:ok, Connection.t()} | {:error, :not_found}
  def get_connection(%Scope{} = scope) do
    team_id = Scope.team_id!(scope)

    case Repo.one(from c in Connection, where: c.team_id == ^team_id, limit: 1) do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  @doc """
  The most recent ERP document mirror for an invoice intent, team-scoped
  (read-only; `nil` when synchronization has never been requested).
  """
  @spec get_document_for_intent(Scope.t(), Ecto.UUID.t()) ::
          BillingCore.ERP.ErpDocument.t() | nil
  def get_document_for_intent(%Scope{} = scope, invoice_intent_id) do
    team_id = Scope.team_id!(scope)

    Repo.one(
      from d in BillingCore.ERP.ErpDocument,
        where: d.team_id == ^team_id and d.invoice_intent_id == ^invoice_intent_id,
        order_by: [desc: d.created_at],
        limit: 1
    )
  end

  @doc """
  Runs the adapter preflight and persists capability evidence (BC-US-004).
  Any `fail` check moves the connection to `action_required`.
  """
  @spec validate_connection(Scope.t(), Connection.t(), map()) ::
          {:ok, Connection.t()} | {:error, term()}
  def validate_connection(%Scope{} = scope, %Connection{} = connection, preflight_input \\ %{}) do
    with :ok <- authorize(scope, [:finance_operator, :team_admin]),
         :ok <- ensure_team(scope, connection.team_id),
         adapter = adapter_for(connection),
         ctx = connection_context(connection),
         {:ok, capabilities} <- adapter.capabilities(ctx),
         {:ok, preflight} <- adapter.preflight(ctx, preflight_input) do
      failed? = Enum.any?(preflight.checks, &(&1.status == :fail))
      status = if failed?, do: "action_required", else: "active"

      {:ok, updated} =
        Repo.transaction(fn ->
          updated =
            connection
            |> Ecto.Changeset.change(
              status: status,
              capabilities: stringify(capabilities),
              capabilities_hash: Canonical.hash(stringify(capabilities)),
              preflight_result: %{"checks" => Enum.map(preflight.checks, &stringify/1)},
              last_validated_at: DateTime.utc_now()
            )
            |> Ecto.Changeset.optimistic_lock(:version)
            |> Repo.update!()

          Audit.record!(scope, "erp.connection.validated",
            aggregate: {:erp_connection, connection.id},
            payload: %{status: status}
          )

          Outbox.emit!("erp_connection.validated.v1",
            aggregate: {:erp_connection, connection.id},
            team_id: connection.team_id,
            correlation_id: scope.correlation_id,
            payload: %{status: status, capabilities_hash: updated.capabilities_hash}
          )

          updated
        end)

      {:ok, updated}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Marks a connection `action_required` (credentials revoked, etc.)."
  @spec mark_action_required!(Connection.t(), String.t()) :: Connection.t()
  def mark_action_required!(%Connection{} = connection, reason) do
    {:ok, updated} =
      Repo.transaction(fn ->
        updated =
          connection
          |> Ecto.Changeset.change(status: "action_required")
          |> Ecto.Changeset.optimistic_lock(:version)
          |> Repo.update!()

        Audit.record!(:system, "erp.connection.action_required",
          aggregate: {:erp_connection, connection.id},
          team_id: connection.team_id,
          payload: %{reason: reason}
        )

        updated
      end)

    updated
  end

  @doc "Resolves the adapter module for a connection's provider."
  @spec adapter_for(Connection.t()) :: module()
  def adapter_for(%Connection{provider: provider}) do
    Map.fetch!(@adapters, provider)
  end

  @doc """
  Builds the adapter connection context. Credentials are resolved through the
  configured secret provider at call time and never persisted.
  """
  @spec connection_context(Connection.t()) :: map()
  def connection_context(%Connection{} = connection) do
    base = %{
      connection_id: connection.id,
      team_id: connection.team_id,
      provider: provider_atom(connection.provider)
    }

    case connection.provider do
      "fake" ->
        case Application.get_env(:billing_core, :fake_erp_context, %{}) do
          %{fake_server: _server} = test_context ->
            Map.merge(base, test_context)

          _no_test_override ->
            resolver =
              Application.get_env(
                :billing_core,
                :fake_erp_context_resolver,
                BillingCore.Demo.FakeERPInstances
              )

            case resolver.context_for(connection) do
              {:ok, demo_context} ->
                Map.merge(base, demo_context)

              {:error, reason} ->
                raise "fake ERP context is unavailable for connection #{connection.id}: #{inspect(reason)}"
            end
        end

      "economic" ->
        credentials = resolve_secret(connection.secret_reference)

        base
        |> Map.put(:credentials, credentials)
        |> Map.merge(Application.get_env(:billing_core, :economic_context_overrides, %{}))
    end
  end

  defp resolve_secret(reference) do
    provider =
      Application.get_env(:billing_core, :secret_provider, BillingCore.ERP.EnvSecretProvider)

    provider.resolve!(reference)
  end

  defp provider_atom("fake"), do: :fake_erp
  defp provider_atom("economic"), do: :economic

  defp stringify(term) do
    term |> Canonical.encode!() |> Jason.decode!()
  end

  defp authorize(%Scope{} = scope, roles) do
    if Scope.has_team_role?(scope, roles), do: :ok, else: {:error, :unauthorized}
  end

  defp ensure_team(%Scope{} = scope, team_id) do
    if Scope.team_id!(scope) == team_id, do: :ok, else: {:error, :unauthorized}
  end
end

defmodule BillingCore.ERP.EnvSecretProvider do
  @moduledoc """
  Default secret provider: resolves `secret_reference` as the name of an
  environment variable holding `app_secret_token:agreement_grant_token`.
  Deployments with a managed secret service configure their own provider.
  """

  @spec resolve!(String.t()) :: map()
  def resolve!(reference) do
    case System.get_env(reference) do
      nil ->
        raise "secret reference #{reference} is not resolvable in this environment"

      value ->
        case String.split(value, ":", parts: 2) do
          [app_secret, grant] ->
            %{app_secret_token: app_secret, agreement_grant_token: grant}

          _ ->
            raise "secret reference #{reference} has an invalid format"
        end
    end
  end
end
