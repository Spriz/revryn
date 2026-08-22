defmodule BillingCore.AuditExport.RetentionTest do
  use BillingCore.DataCase, async: false

  import Ecto.Query

  alias BillingCore.AuditExport.Retention
  alias BillingCore.{Audit, Repo}

  test "every billing-schema table carries exactly one retention classification" do
    assert Retention.unclassified_tables() == []

    classes = Retention.classes()

    all =
      classes.financial_evidence ++
        classes.identity_access ++ classes.operational ++ classes.raw_usage

    assert length(all) == length(Enum.uniq(all)), "a table is classified twice"

    # SPEC §20: raw usage is the team-configurable class; the dedup ledger
    # stays financial so pruned events can never replay as new.
    assert classes.raw_usage == ["usage_events"]
    assert "usage_event_keys" in classes.financial_evidence
  end

  test "raw-usage pruning honors the team window, the freeze boundary, and the floor" do
    scope = BillingCore.UsageFixtures.usage_scope_fixture([:billing_admin])
    subscription = BillingCore.UsageFixtures.usage_subscription_fixture(scope)
    {:ok, _} = BillingCore.Usage.ensure_partitions(1)
    team_id = BillingCore.Scope.team_id!(scope)

    old = DateTime.add(DateTime.utc_now(), -200 * 86_400, :second)
    recent = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    # Widen the ingest age window for the fixture (the retention floor is
    # what this test exercises, not §13.1 lateness policy) and cover the
    # old month with a partition.
    previous_usage = Application.get_env(:billing_core, BillingCore.Usage)

    Application.put_env(
      :billing_core,
      BillingCore.Usage,
      Keyword.put(previous_usage || [], :max_age_days, 400)
    )

    on_exit(fn -> restore_env(BillingCore.Usage, previous_usage) end)

    Repo.query!("SELECT billing.ensure_usage_partition($1)", [
      old |> DateTime.to_date() |> Date.beginning_of_month()
    ])

    for occurred_at <- [old, recent] do
      {:ok, %{status: :accepted}} =
        BillingCore.Usage.ingest_event(
          scope,
          BillingCore.UsageFixtures.valid_usage_event_attrs(subscription,
            occurred_at: occurred_at
          )
        )
    end

    count_events = fn ->
      Repo.one(
        from e in "usage_events",
          prefix: "billing",
          where: e.team_id == type(^team_id, Ecto.UUID),
          select: count()
      )
    end

    assert count_events.() == 2

    # No configuration → nothing pruned.
    assert Retention.enforce_raw_usage() == %{}
    assert count_events.() == 2

    # Configured, but nothing frozen yet → still nothing prunable.
    {:ok, _} =
      BillingCore.Orgs.update_team_settings(
        scope.team,
        %{"raw_usage_retention_days" => 30},
        scope
      )

    assert %{^team_id => 0} = Retention.enforce_raw_usage()
    assert count_events.() == 2

    # A freeze whose cutoff covers the old event makes it prunable — but
    # only past the clamped floor (the configured 30 clamps to 90), so the
    # 10-day-old event survives even though the freeze consumed it.
    freeze_intent_with_cutoff!(team_id, DateTime.utc_now())

    assert %{^team_id => 1} = Retention.enforce_raw_usage()
    assert count_events.() == 1

    assert Repo.exists?(
             from a in Audit.Entry,
               where: a.event_type == "retention.raw_usage_pruned"
           )
  end

  defp freeze_intent_with_cutoff!(team_id, cutoff) do
    now = DateTime.utc_now()

    chain =
      Repo.insert!(%BillingCore.Billing.InvoiceChain{team_id: team_id})

    customer =
      Repo.insert!(%BillingCore.Contracts.Customer{
        team_id: team_id,
        external_id: "ret-cust-#{System.unique_integer([:positive])}",
        status: :active,
        current_version: 1
      })

    Repo.insert!(%BillingCore.Billing.InvoiceIntent{
      id: Ecto.UUID.generate(),
      team_id: team_id,
      invoice_chain_id: chain.id,
      customer_id: customer.id,
      customer_version: 1,
      currency: "DKK",
      invoice_date: Date.utc_today(),
      intent_version: 1,
      document_kind: "invoice",
      canonical_snapshot: %{"usageCutoff" => DateTime.to_iso8601(cutoff)},
      content_hash: "retention-test",
      net_amount_minor: 0,
      created_at: now,
      frozen_at: now
    })
  end

  test "schema/audit.yaml matches the generated classification artifact" do
    generated = Retention.to_yaml()
    checked_in = File.read!(Path.expand("../../../schema/audit.yaml", __DIR__))

    assert checked_in == generated, """
    schema/audit.yaml is stale. Regenerate with:

        mix run --no-start -e 'File.write!("schema/audit.yaml", \
    BillingCore.AuditExport.Retention.to_yaml())'
    """
  end

  test "the financial hold clamps to at least six years" do
    created_at = ~U[2026-01-01 00:00:00Z]
    assert Retention.financial_hold_until(created_at).year == 2032

    previous = Application.get_env(:billing_core, :retention)
    Application.put_env(:billing_core, :retention, financial_retention_years: 1)
    on_exit(fn -> restore_env(:retention, previous) end)

    assert Retention.financial_hold_until(created_at).year == 2032

    Application.put_env(:billing_core, :retention, financial_retention_years: 10)
    assert Retention.financial_hold_until(created_at).year == 2036
  end

  test "enforce prunes only allowlisted operational rows past their windows" do
    scope = BillingCore.ContractsFixtures.billing_scope_fixture([:team_admin])

    {:ok, connection} =
      BillingCore.ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    old = DateTime.add(DateTime.utc_now(), -120 * 86_400, :second)
    fresh = DateTime.utc_now()

    Repo.insert_all(
      "webhook_receipts",
      [
        webhook_receipt(connection, old),
        webhook_receipt(connection, fresh)
      ],
      prefix: "billing"
    )

    # A durable financial fact from the same era is untouchable.
    entry = Audit.record!(:system, "retention.test_marker", payload: %{})

    counts = Retention.enforce()
    assert counts["webhook_receipts"] == 1

    remaining =
      Repo.all(from r in "webhook_receipts", prefix: "billing", select: r.payload_hash)

    assert remaining == ["fresh"]

    assert Repo.one(
             from e in Audit.Entry,
               where: e.event_type == "retention.operational_prune_completed",
               order_by: [desc: e.occurred_at],
               limit: 1
           )

    assert Repo.get!(Audit.Entry, entry.id)
  end

  defp webhook_receipt(connection, received_at) do
    %{
      id: Ecto.UUID.dump!(Ecto.UUID.generate()),
      provider: "fake",
      team_id: Ecto.UUID.dump!(connection.team_id),
      erp_connection_id: Ecto.UUID.dump!(connection.id),
      received_at: received_at,
      headers_redacted: %{},
      payload_redacted: %{},
      payload_hash:
        if(DateTime.after?(received_at, DateTime.add(DateTime.utc_now(), -1, :day)),
          do: "fresh",
          else: "old"
        )
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:billing_core, key)
  defp restore_env(key, value), do: Application.put_env(:billing_core, key, value)
end
