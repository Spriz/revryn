defmodule BillingCore.AuditExport.Retention do
  @moduledoc """
  Retention classification and enforcement (SPEC §20, BC-TASK-072).

  Every table in the `billing` schema is classified into exactly one
  retention class; `schema/audit.yaml` is the reviewed artifact rendered
  from this module and a test keeps the two identical and complete against
  the live schema (a new table without a classification fails CI).

  Classes:

    * `financial_evidence` — the transaction/control trail. Never touched
      by automation; deletable only under the accountant-approved policy in
      `docs/accounting/retention.md` (default hold: six years, configurable
      upward, never below the applicable legal requirement).
    * `identity_access` — who exists and who could act. Retained while the
      account/membership is live plus the approved tail; changes are
      themselves audit facts.
    * `operational` — delivery/dedup/diagnostic machinery whose durable
      truth lives elsewhere. Prunable by `enforce/0` after per-table
      windows; each prune run records an audit fact with counts.

  `enforce/0` is deliberately allowlist-driven: it can only ever delete
  from the tables named in `@prunable` — a financial table can not become
  prunable without changing this module, the YAML artifact, and the tests.
  """

  import Ecto.Query

  alias BillingCore.{Audit, Repo}

  @default_financial_retention_years 6

  # SPEC §20: team-configurable raw-usage retention never goes below this
  # floor — dispute and audit needs outrank storage preferences.
  @raw_usage_min_days 90

  @financial_evidence ~w(
    account_team_customers accounts approval_records audit_log billing_runs
    charge_instances charges contract_versions contracts correction_cases
    credit_close_transaction_memberships credit_disposition_policy_versions
    customer_credit_accounts customer_credit_close_approvals
    customer_credit_close_evidence customer_credit_close_movements
    customer_credit_close_policy_versions customer_credit_closes
    customer_credit_grants customer_credit_settlements
    customer_credit_transactions customer_erp_mappings
    customer_versions customers discount_assignments discount_versions
    discounts erp_connections erp_documents invoice_chains
    invoice_intent_lifecycle invoice_intent_state_transitions invoice_intents
    invoice_lines operation_transitions operations organizations
    plan_versions plans price_components product_erp_mappings
    product_versions products reconciliation_results subscription_changes
    subscription_versions subscriptions sync_operations team_settings_versions
    teams usage_event_keys usage_quarantine
  )

  # SPEC §20: raw usage is team-configurable AFTER invoice freeze — the
  # frozen calculation traces are the financial evidence; the raw rows are
  # replay/dispute material with a bounded, team-declared hold. The dedup
  # ledger (`usage_event_keys`) is never pruned so a deleted event can not
  # be replayed as new.
  @raw_usage ~w(usage_events)

  @identity_access ~w(
    federated_identities organization_invitations organization_memberships
    recovery_codes team_memberships totp_factors user_emails users
    webauthn_credentials
  )

  @operational ~w(
    demo_workspaces fake_erp_instances idempotency_records outbox_events
    sessions webhook_receipts
  )

  # Monthly usage partitions inherit the usage_events classification.
  @partition_prefixes ["usage_events_y"]

  # {table, config-key, default window, what qualifies for pruning}
  @prunable [
    {"webhook_receipts", :webhook_receipt_days, 90, :received_before_cutoff},
    {"outbox_events", :published_outbox_days, 30, :published_before_cutoff},
    {"idempotency_records", :expired_idempotency_days, 30, :expired_before_cutoff},
    {"sessions", :dead_session_days, 30, :dead_before_cutoff}
  ]

  @spec classes() :: %{atom() => [String.t()]}
  def classes do
    %{
      financial_evidence: @financial_evidence,
      identity_access: @identity_access,
      operational: @operational,
      raw_usage: @raw_usage
    }
  end

  @spec partition_prefixes() :: [String.t()]
  def partition_prefixes, do: @partition_prefixes

  @spec financial_retention_years() :: pos_integer()
  def financial_retention_years do
    config = Application.get_env(:billing_core, :retention, [])
    years = Keyword.get(config, :financial_retention_years, @default_financial_retention_years)
    max(years, @default_financial_retention_years)
  end

  @doc "Earliest instant at which financial evidence created at `created_at` may even be considered for archival under approved policy."
  @spec financial_hold_until(DateTime.t()) :: DateTime.t()
  def financial_hold_until(%DateTime{} = created_at) do
    DateTime.shift(created_at, year: financial_retention_years())
  end

  @doc "Tables present in the live billing schema but missing a classification."
  @spec unclassified_tables() :: [String.t()]
  def unclassified_tables do
    classified =
      MapSet.new(@financial_evidence ++ @identity_access ++ @operational ++ @raw_usage)

    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'billing' AND table_type = 'BASE TABLE'"
    |> Repo.query!()
    |> Map.fetch!(:rows)
    |> List.flatten()
    |> Enum.reject(fn table ->
      MapSet.member?(classified, table) or
        Enum.any?(@partition_prefixes, &String.starts_with?(table, &1))
    end)
    |> Enum.sort()
  end

  @doc """
  Prunes operational data past its window. Deletes only from the fixed
  allowlist; records one audit fact summarizing the run.
  """
  @spec enforce() :: %{String.t() => non_neg_integer()}
  def enforce do
    now = DateTime.utc_now()
    config = Application.get_env(:billing_core, :retention, [])

    counts =
      Map.new(@prunable, fn {table, config_key, default_days, rule} ->
        days = Keyword.get(config, config_key, default_days)
        cutoff = DateTime.add(now, -days * 86_400, :second)
        {table, prune!(table, rule, cutoff, now)}
      end)

    Audit.record!(:system, "retention.operational_prune_completed", payload: counts)

    :telemetry.execute(
      [:billing_core, :retention, :pruned],
      %{count: counts |> Map.values() |> Enum.sum()},
      %{}
    )

    counts
  end

  @spec raw_usage_min_days() :: pos_integer()
  def raw_usage_min_days, do: @raw_usage_min_days

  @doc """
  Prunes billed raw usage per team-configured windows (SPEC §20).

  A team opts in by carrying `"raw_usage_retention_days"` in its current
  settings snapshot (clamped to at least #{@raw_usage_min_days} days). Only
  events an invoice freeze has already consumed are eligible: the row's
  `occurred_at` must fall before the team's newest frozen usage cutoff AND
  before the retention window. The dedup ledger is never touched, so a
  pruned event replayed by an integration still deduplicates. Each team's
  prune records an audit fact with the count.
  """
  @spec enforce_raw_usage() :: %{Ecto.UUID.t() => non_neg_integer()}
  def enforce_raw_usage do
    now = DateTime.utc_now()

    configured_teams()
    |> Map.new(fn {team_id, days} ->
      window_cutoff = DateTime.add(now, -max(days, @raw_usage_min_days) * 86_400, :second)

      count =
        case newest_frozen_cutoff(team_id) do
          nil ->
            0

          frozen_cutoff ->
            cutoff =
              if DateTime.before?(frozen_cutoff, window_cutoff),
                do: frozen_cutoff,
                else: window_cutoff

            # The delete gate lives for exactly this transaction — no other
            # code path can remove usage rows (append-only trigger).
            {:ok, count} =
              Repo.transaction(fn ->
                Repo.query!("SET LOCAL billing.raw_usage_prune = 'on'")

                {count, _} =
                  Repo.delete_all(
                    from e in "usage_events",
                      prefix: "billing",
                      where:
                        e.team_id == type(^team_id, Ecto.UUID) and
                          e.occurred_at < ^cutoff
                  )

                count
              end)

            count
        end

      if count > 0 do
        Audit.record!(:system, "retention.raw_usage_pruned",
          team_id: team_id,
          payload: %{count: count, configured_days: days}
        )
      end

      {team_id, count}
    end)
  end

  # The NEWEST settings snapshot decides — a team that later removes the
  # key stops pruning, so filter after picking the current version.
  defp configured_teams do
    Repo.all(
      from v in "team_settings_versions",
        prefix: "billing",
        distinct: v.team_id,
        order_by: [asc: v.team_id, desc: v.version],
        select: {type(v.team_id, Ecto.UUID), v.settings}
    )
    |> Enum.flat_map(fn {team_id, settings} ->
      case settings["raw_usage_retention_days"] do
        days when is_integer(days) and days > 0 -> [{team_id, days}]
        days when is_binary(days) -> parse_days(team_id, days)
        _other -> []
      end
    end)
  end

  defp parse_days(team_id, days) do
    case Integer.parse(days) do
      {parsed, ""} when parsed > 0 -> [{team_id, parsed}]
      _other -> []
    end
  end

  defp newest_frozen_cutoff(team_id) do
    Repo.one(
      from i in "invoice_intents",
        prefix: "billing",
        where: i.team_id == type(^team_id, Ecto.UUID) and not is_nil(i.frozen_at),
        select: max(fragment("(?->>'usageCutoff')::timestamptz", i.canonical_snapshot))
    )
  end

  defp prune!("webhook_receipts", :received_before_cutoff, cutoff, _now) do
    {count, _} =
      Repo.delete_all(
        from r in "webhook_receipts", prefix: "billing", where: r.received_at < ^cutoff
      )

    count
  end

  defp prune!("outbox_events", :published_before_cutoff, cutoff, _now) do
    {count, _} =
      Repo.delete_all(
        from e in "outbox_events",
          prefix: "billing",
          where: not is_nil(e.published_at) and e.published_at < ^cutoff
      )

    count
  end

  defp prune!("idempotency_records", :expired_before_cutoff, cutoff, _now) do
    {count, _} =
      Repo.delete_all(
        from r in "idempotency_records", prefix: "billing", where: r.expires_at < ^cutoff
      )

    count
  end

  defp prune!("sessions", :dead_before_cutoff, cutoff, _now) do
    {count, _} =
      Repo.delete_all(
        from s in "sessions",
          prefix: "billing",
          where:
            (not is_nil(s.revoked_at) and s.revoked_at < ^cutoff) or
              s.expires_at < ^cutoff
      )

    count
  end

  @doc "Renders the reviewed `schema/audit.yaml` artifact deterministically."
  @spec to_yaml() :: String.t()
  def to_yaml do
    prune_lines =
      Enum.map_join(@prunable, "\n", fn {table, config_key, default_days, _rule} ->
        "  - table: #{table}\n    config_key: #{config_key}\n    default_window_days: #{default_days}"
      end)

    """
    # Generated from BillingCore.AuditExport.Retention — do not edit by hand.
    # Regenerate with:
    #   mix run --no-start -e 'File.write!("schema/audit.yaml", BillingCore.AuditExport.Retention.to_yaml())'
    version: 1
    default_financial_retention_years: #{@default_financial_retention_years}
    partition_prefixes:
    #{Enum.map_join(@partition_prefixes, "\n", &"  - #{&1}")}
    classes:
      financial_evidence:
        policy: never pruned by automation; accountant-approved policy only (docs/accounting/retention.md)
        tables:
    #{Enum.map_join(@financial_evidence, "\n", &"      - #{&1}")}
      identity_access:
        policy: retained while the identity/membership is live plus the approved tail
        tables:
    #{Enum.map_join(@identity_access, "\n", &"      - #{&1}")}
      operational:
        policy: prunable machinery; durable truth lives in financial_evidence tables
        tables:
    #{Enum.map_join(@operational, "\n", &"      - #{&1}")}
      raw_usage:
        policy: team-configurable retention after invoice freeze (SPEC section 20, min #{@raw_usage_min_days} days); frozen calculation traces remain the financial evidence
        tables:
    #{Enum.map_join(@raw_usage, "\n", &"      - #{&1}")}
    prunable:
    #{prune_lines}
    """
  end
end
