defmodule BillingCore.Idempotency do
  @moduledoc """
  Generic idempotency records over `billing.idempotency_records`
  (SPEC §14.3, INV-008).

  Deduplication scope is `(team, command family, key)`; the original
  principal is stored as evidence but is not part of deduplication. The
  canonical command input — not transport headers — is hashed with
  `BillingCore.Domain.Canonical.hash/1` and persisted, so replays of the
  same canonical command return the stored minimal response body while a
  reused key with materially different input is a typed
  `:idempotency_key_reused` error.

  Records are retained for at least #{30} days (financial retention floor).
  """

  import Ecto.Query

  alias BillingCore.Domain.Canonical
  alias BillingCore.Repo

  @retention_days 30

  @type outcome ::
          {:executed, map()}
          | {:replayed, map()}
          | {:error, :idempotency_key_reused}
          | {:error, term()}

  @doc """
  Executes `fun` exactly once for `(team_id, command_family, key)`.

  `fun` must return `{:ok, response_body}` (a minimal JSON-safe map that can
  be replayed later, e.g. `%{"resource_reference" => id}`) or
  `{:error, reason}`. On the first call the fun runs inside a transaction
  that also inserts the idempotency record — failed commands leave no
  record. A replay with the same request hash returns `{:replayed, body}`;
  callers re-resolve authorization and re-fetch the referenced resource. A
  concurrent duplicate insert aborts the losing transaction and is treated
  as a replay.
  """
  @spec run(Ecto.UUID.t(), String.t(), String.t(), String.t() | nil, term(), (-> term())) ::
          outcome()
  def run(team_id, command_family, key, principal_id, canonical_input, fun)
      when is_binary(command_family) and is_binary(key) and is_function(fun, 0) do
    request_hash = Canonical.hash(canonical_input)

    case fetch(team_id, command_family, key) do
      %{request_hash: ^request_hash} = record ->
        {:replayed, record.response_body || %{}}

      %{} ->
        {:error, :idempotency_key_reused}

      nil ->
        execute(team_id, command_family, key, principal_id, request_hash, fun)
    end
  end

  defp execute(team_id, command_family, key, principal_id, request_hash, fun) do
    result =
      Repo.transaction(fn ->
        case fun.() do
          {:ok, %{} = response_body} ->
            insert_record!(
              team_id,
              command_family,
              key,
              principal_id,
              request_hash,
              response_body
            )

            response_body

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, response_body} -> {:executed, response_body}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Postgrex.Error, Ecto.ConstraintError] ->
      if unique_violation?(error) do
        # Concurrent duplicate: the winner's record is committed; treat as replay.
        case fetch(team_id, command_family, key) do
          %{request_hash: ^request_hash} = record -> {:replayed, record.response_body || %{}}
          %{} -> {:error, :idempotency_key_reused}
          nil -> reraise(error, __STACKTRACE__)
        end
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp fetch(team_id, command_family, key) do
    Repo.one(
      from r in "idempotency_records",
        prefix: "billing",
        where:
          r.team_id == type(^team_id, Ecto.UUID) and r.command_family == ^command_family and
            r.key == ^key,
        select: %{request_hash: r.request_hash, response_body: r.response_body}
    )
  end

  defp insert_record!(team_id, command_family, key, principal_id, request_hash, response_body) do
    now = DateTime.utc_now()

    Repo.insert_all(
      "idempotency_records",
      [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          team_id: Ecto.UUID.dump!(team_id),
          command_family: command_family,
          original_principal_id: principal_id || "unknown",
          key: key,
          request_hash: request_hash,
          response_status: 200,
          response_body: response_body,
          resource_reference: response_body["resource_reference"],
          expires_at: DateTime.add(now, @retention_days, :day),
          created_at: now
        }
      ],
      prefix: "billing"
    )
  end

  defp unique_violation?(%Ecto.ConstraintError{type: :unique}), do: true

  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true

  defp unique_violation?(_error), do: false
end
