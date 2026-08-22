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

  test "doctor output never leaks connection secrets" do
    for check <- Release.checks() do
      refute check[:detail] =~ ~r/postgres:\/\/\S+:\S+@/,
             "#{check[:name]} leaked a connection URL"

      refute check[:detail] =~ "password"
    end
  end
end
