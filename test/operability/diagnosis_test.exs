defmodule BillingCore.Operability.DiagnosisTest do
  @moduledoc """
  BC-TASK-095 acceptance: seeded failures across the named families are
  diagnosable from supported surfaces alone — the doctor, the health
  endpoints, and the operations inbox — never raw SQL or IEx. The ERP
  family's four remediation scenarios live in the operations-inbox
  LiveView/Playwright suites; this file certifies the doctor's coverage
  and redaction plus the health surface.
  """

  use BillingCore.DataCase, async: false

  import ExUnit.CaptureIO

  alias BillingCore.Release

  test "the doctor covers database, migrations, config, SMTP, queues, and clock" do
    checks = Release.checks()
    names = Enum.map(checks, & &1[:name])

    assert names == ["database", "migrations", "secret_key_base", "smtp", "queues", "clock"]

    by_name = Map.new(checks, &{&1[:name], &1})
    assert by_name["database"][:status] == :pass
    assert by_name["migrations"][:status] == :pass
    # Test env uses the local/test adapter — reported, not failed.
    assert by_name["smtp"][:status] in [:pass, :warn]
    assert by_name["queues"][:status] in [:pass, :warn]
  end

  test "a seeded queue failure surfaces in the doctor without SQL access" do
    # A discarded job is dead work an operator must notice.
    Repo.insert_all(
      "oban_jobs",
      [
        %{
          queue: "erp",
          worker: "BillingCore.ERP.SyncWorker",
          args: %{},
          state: "discarded",
          attempt: 20,
          max_attempts: 20,
          inserted_at: DateTime.utc_now(),
          scheduled_at: DateTime.utc_now()
        }
      ],
      prefix: "public"
    )

    queues = Enum.find(Release.checks(), &(&1[:name] == "queues"))
    assert queues[:status] == :warn
    assert queues[:detail] =~ "discarded=1"
  end

  test "seeded SMTP misconfiguration fails the doctor with a named gap" do
    previous = Application.get_env(:billing_core, BillingCore.Mailer)

    Application.put_env(:billing_core, BillingCore.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: nil,
      port: 587
    )

    on_exit(fn -> Application.put_env(:billing_core, BillingCore.Mailer, previous) end)

    smtp = Enum.find(Release.checks(), &(&1[:name] == "smtp"))
    assert smtp[:status] == :fail
    assert smtp[:detail] =~ "relay"
  end

  test "doctor/0 prints one aligned status line per check and returns :ok" do
    # No check fails in the test environment, so the `System.stop(1)`
    # branch is not taken (running it would halt the test VM; that exit
    # path stays uncovered by design and is exercised only in a real
    # release).
    {result, output} = with_io(fn -> Release.doctor() end)

    assert result == :ok
    lines = output |> String.trim_trailing() |> String.split("\n")
    assert length(lines) == 6

    for line <- lines do
      assert line =~ ~r/^\[(PASS|WARN|FAIL)\s*\] [a-z_]+: ./
    end

    assert Enum.any?(lines, &(&1 =~ "database: reachable"))
    assert Enum.any?(lines, &(&1 =~ "migrations: up to date"))
  end

  test "doctor(:json) emits machine-readable checks with the same content" do
    {result, output} = with_io(fn -> Release.doctor(:json) end)

    assert result == :ok
    assert %{"checks" => checks} = Jason.decode!(output)

    names = Enum.map(checks, & &1["name"])
    assert names == ["database", "migrations", "secret_key_base", "smtp", "queues", "clock"]

    for check <- checks do
      assert check["status"] in ["pass", "warn", "fail"]
      assert is_binary(check["detail"])
    end
  end

  test "migrate/0 is a safe no-op on an up-to-date database" do
    # In a release this runs all pending migrations; against the fully
    # migrated test database each repo reports an empty run.
    assert [{:ok, [], _apps}] = Release.migrate()
  end

  test "rollback/2 targeted above the newest applied migration reverts nothing" do
    # rollback/2 with `to:` reverts every migration newer than the target;
    # a target beyond the newest version proves the wiring without
    # destroying schema state. A real downgrade needs a disposable database
    # and is exercised in release smoke tests, not here.
    assert {:ok, [], _apps} = Release.rollback(BillingCore.Repo, 99_999_999_999_999)
  end

  test "a fully configured SMTP transport passes the doctor" do
    previous = Application.get_env(:billing_core, BillingCore.Mailer)

    Application.put_env(:billing_core, BillingCore.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: "smtp.example.test",
      port: 587
    )

    on_exit(fn -> Application.put_env(:billing_core, BillingCore.Mailer, previous) end)

    smtp = Enum.find(Release.checks(), &(&1[:name] == "smtp"))
    assert smtp == %{name: "smtp", status: :pass, detail: "SMTP transport configured"}
  end

  test "a missing mailer adapter is a warning, not a failure" do
    previous = Application.get_env(:billing_core, BillingCore.Mailer)
    Application.put_env(:billing_core, BillingCore.Mailer, [])
    on_exit(fn -> Application.put_env(:billing_core, BillingCore.Mailer, previous) end)

    smtp = Enum.find(Release.checks(), &(&1[:name] == "smtp"))
    assert smtp[:status] == :warn
    assert smtp[:detail] == "no mailer adapter configured"
  end

  test "a missing or short secret_key_base fails the doctor by name" do
    previous = Application.get_env(:billing_core, BillingCoreWeb.Endpoint)

    on_exit(fn ->
      Application.put_env(:billing_core, BillingCoreWeb.Endpoint, previous)
    end)

    # The check reads the application environment; the already-booted
    # endpoint keeps its own cached config, so this seeding is safe.
    Application.put_env(
      :billing_core,
      BillingCoreWeb.Endpoint,
      Keyword.delete(previous, :secret_key_base)
    )

    missing = Enum.find(Release.checks(), &(&1[:name] == "secret_key_base"))
    assert missing == %{name: "secret_key_base", status: :fail, detail: "not configured"}

    Application.put_env(
      :billing_core,
      BillingCoreWeb.Endpoint,
      Keyword.put(previous, :secret_key_base, "short")
    )

    short = Enum.find(Release.checks(), &(&1[:name] == "secret_key_base"))
    assert short == %{name: "secret_key_base", status: :fail, detail: "too short"}
  end

  test "a seeded pending migration fails the migrations check with the count" do
    # Removing the newest recorded version inside the sandbox transaction
    # makes exactly one migration report :down; the sandbox rolls it back.
    %{num_rows: 1} =
      Repo.query!(
        "DELETE FROM public.schema_migrations WHERE version = " <>
          "(SELECT max(version) FROM public.schema_migrations)"
      )

    migrations = Enum.find(Release.checks(), &(&1[:name] == "migrations"))
    assert migrations[:status] == :fail
    assert migrations[:detail] == "1 pending migrations"
  end

  test "an unreadable queue table fails the queues check with a redacted error" do
    # Simulates the operational failure mode "Oban tables missing/broken"
    # without leaving state behind: DDL inside the sandbox transaction is
    # rolled back with everything else.
    Repo.query!("ALTER TABLE public.oban_jobs RENAME TO oban_jobs_seeded_away")

    queues = Enum.find(Release.checks(), &(&1[:name] == "queues"))
    assert queues[:status] == :fail
    assert queues[:detail] =~ "oban_jobs"
    # redact/1 caps the detail so stack-sized errors never flood the doctor.
    assert String.length(queues[:detail]) <= 300
  end

  # Branches that need a genuinely broken runtime and stay uncovered here:
  #
  #   * check_database's rescue — requires the database itself to be
  #     unreachable; stopping the Repo would tear down the shared sandbox
  #     for the whole suite.
  #   * check_migrations' rescue — Ecto.Migrator recreates a missing
  #     schema_migrations table before reading it (verified: renaming the
  #     table yields the "pending migrations" failure, not the rescue), so
  #     only a dead connection reaches it, same as check_database.
  #   * check_clock's drift warning — both sides of the comparison read the
  #     real clocks, so a >=5s os/runtime drift cannot be seeded.
  #   * doctor/1's `System.stop(1)` on a failed check — would halt the
  #     test VM; exercised only in a real release.

  test "doctor output never leaks connection secrets" do
    for check <- Release.checks() do
      refute check[:detail] =~ ~r/postgres:\/\/\S+:\S+@/,
             "#{check[:name]} leaked a connection URL"

      refute check[:detail] =~ "password"
    end
  end
end
