defmodule BillingCore.IdempotencyTest do
  @moduledoc """
  SPEC §14.3 / INV-008: exactly-once command execution keyed by
  `(team, command family, key)`, canonical-input hashing, replay of the
  stored minimal body, and typed key-reuse errors. The genuinely concurrent
  duplicate-insert race (two committed writers) cannot be produced inside
  the SQL sandbox — its reachable in-transaction halves (a unique violation
  with no committed winner, and non-unique database errors) are covered
  below instead.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.Domain.Canonical
  alias BillingCore.Idempotency

  @family "credits.grant"

  defp record_count(team_id) do
    Repo.aggregate(
      from(r in "idempotency_records",
        prefix: "billing",
        where: r.team_id == type(^team_id, Ecto.UUID)
      ),
      :count
    )
  end

  defp fetch_record(team_id, key) do
    Repo.one(
      from(r in "idempotency_records",
        prefix: "billing",
        where: r.team_id == type(^team_id, Ecto.UUID) and r.key == ^key,
        select: %{
          command_family: r.command_family,
          original_principal_id: r.original_principal_id,
          request_hash: r.request_hash,
          response_status: r.response_status,
          response_body: r.response_body,
          resource_reference: r.resource_reference,
          expires_at: r.expires_at
        }
      )
    )
  end

  defp raw_record(team_id, key, attrs) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: Ecto.UUID.dump!(Ecto.UUID.generate()),
        team_id: Ecto.UUID.dump!(team_id),
        command_family: @family,
        original_principal_id: "seed",
        key: key,
        request_hash: "seed-hash",
        expires_at: DateTime.add(now, 30, :day),
        created_at: now
      },
      attrs
    )
  end

  test "first execution runs the command and persists the evidence record" do
    team = Ecto.UUID.generate()
    input = %{"amount_minor" => 100, "currency" => "DKK"}

    assert {:executed, %{"resource_reference" => "grant-1"}} =
             Idempotency.run(team, @family, "key-1", "user-1", input, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)

    record = fetch_record(team, "key-1")
    assert record.command_family == @family
    assert record.original_principal_id == "user-1"
    assert record.request_hash == Canonical.hash(input)
    assert record.response_status == 200
    assert record.response_body == %{"resource_reference" => "grant-1"}
    assert record.resource_reference == "grant-1"
    # Financial retention floor: at least 30 days. Schemaless selects return
    # naive datetimes, so compare in naive UTC.
    assert NaiveDateTime.diff(record.expires_at, NaiveDateTime.utc_now(), :day) >= 29
  end

  test "a nil principal is stored as evidence placeholder, never dropped" do
    team = Ecto.UUID.generate()

    assert {:executed, _} =
             Idempotency.run(team, @family, "key-1", nil, %{}, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)

    assert fetch_record(team, "key-1").original_principal_id == "unknown"
  end

  test "replay of the same canonical input returns the stored body without re-executing" do
    team = Ecto.UUID.generate()
    input = %{"amount_minor" => 100}

    assert {:executed, _} =
             Idempotency.run(team, @family, "key-1", "user-1", input, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)

    assert {:replayed, %{"resource_reference" => "grant-1"}} =
             Idempotency.run(team, @family, "key-1", "user-1", input, fn ->
               flunk("command must not re-execute on replay")
             end)

    assert record_count(team) == 1
  end

  test "the same canonical input hashes identically regardless of key order or atom keys" do
    team = Ecto.UUID.generate()

    assert {:executed, _} =
             Idempotency.run(team, @family, "key-1", "user-1", %{"a" => 1, "b" => 2}, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)

    assert {:replayed, _} =
             Idempotency.run(team, @family, "key-1", "user-1", %{b: 2, a: 1}, fn ->
               flunk("command must not re-execute on replay")
             end)
  end

  test "reusing a key with materially different input is a typed error" do
    team = Ecto.UUID.generate()

    assert {:executed, _} =
             Idempotency.run(team, @family, "key-1", "user-1", %{"amount_minor" => 100}, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)

    assert {:error, :idempotency_key_reused} =
             Idempotency.run(team, @family, "key-1", "user-1", %{"amount_minor" => 200}, fn ->
               flunk("command must not execute under a reused key")
             end)

    assert record_count(team) == 1
  end

  test "deduplication is scoped per team and per command family" do
    team = Ecto.UUID.generate()
    other_team = Ecto.UUID.generate()

    assert {:executed, _} =
             Idempotency.run(team, @family, "key-1", "user-1", %{}, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)

    assert {:executed, %{"resource_reference" => "other-family"}} =
             Idempotency.run(team, "credits.refund", "key-1", "user-1", %{}, fn ->
               {:ok, %{"resource_reference" => "other-family"}}
             end)

    assert {:executed, %{"resource_reference" => "other-team"}} =
             Idempotency.run(other_team, @family, "key-1", "user-1", %{}, fn ->
               {:ok, %{"resource_reference" => "other-team"}}
             end)
  end

  test "failed commands roll back their own writes and leave no record" do
    team = Ecto.UUID.generate()

    assert {:error, :quota_exceeded} =
             Idempotency.run(team, @family, "key-1", "user-1", %{}, fn ->
               # A write performed by the command itself must vanish with it.
               Repo.insert_all("idempotency_records", [raw_record(team, "side-effect", %{})],
                 prefix: "billing"
               )

               {:error, :quota_exceeded}
             end)

    assert record_count(team) == 0

    # The key is free again: the command retries and succeeds.
    assert {:executed, %{"resource_reference" => "grant-1"}} =
             Idempotency.run(team, @family, "key-1", "user-1", %{}, fn ->
               {:ok, %{"resource_reference" => "grant-1"}}
             end)
  end

  test "a record stored without a response body replays as an empty map" do
    team = Ecto.UUID.generate()
    input = %{"amount_minor" => 100}

    Repo.insert_all(
      "idempotency_records",
      [raw_record(team, "key-1", %{request_hash: Canonical.hash(input), response_body: nil})],
      prefix: "billing"
    )

    assert {:replayed, %{}} =
             Idempotency.run(team, @family, "key-1", "user-1", input, fn ->
               flunk("command must not re-execute on replay")
             end)
  end

  test "a unique violation with no committed winner record is reraised, not masked as replay" do
    team = Ecto.UUID.generate()
    duplicate = raw_record(team, "unrelated-key", %{command_family: "unrelated.family"})

    assert_raise Postgrex.Error, fn ->
      Idempotency.run(team, @family, "key-1", "user-1", %{}, fn ->
        Repo.insert_all("idempotency_records", [duplicate], prefix: "billing")
        # Same primary key again: raises a unique violation inside the txn.
        Repo.insert_all("idempotency_records", [duplicate], prefix: "billing")
        {:ok, %{}}
      end)
    end

    assert record_count(team) == 0
  end

  test "non-unique database errors are reraised untouched" do
    team = Ecto.UUID.generate()
    broken = Map.delete(raw_record(team, "key-1", %{}), :team_id)

    assert_raise Postgrex.Error, ~r/not_null|null value/i, fn ->
      Idempotency.run(team, @family, "key-1", "user-1", %{}, fn ->
        Repo.insert_all("idempotency_records", [broken], prefix: "billing")
        {:ok, %{}}
      end)
    end

    assert record_count(team) == 0
  end
end
