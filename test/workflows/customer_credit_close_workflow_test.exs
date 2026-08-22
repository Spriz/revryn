defmodule BillingCore.Workflows.CustomerCreditCloseWorkflowTest do
  @moduledoc """
  Durable customer-credit close workflow (SPEC §11.5, §13.3, BC-US-163…165).

  These tests deliberately cross the command, PostgreSQL, Oban, and fake-ERP
  boundaries: the ledger snapshot is frozen before approval and every ERP
  effect is found by its stable external reference before it is created again.
  """

  use BillingCore.DataCase, async: false

  import Ecto.Query
  import BillingCore.CreditsFixtures

  alias BillingCore.{ERP, Operations, Repo}
  alias BillingCore.Credits.Close, as: CloseKernel
  alias BillingCore.Credits.Close.{Approval, Evidence, Movement, TransactionMembership}
  alias BillingCore.Credits.Close.Close, as: CreditClose
  alias BillingCore.Credits.CloseWorkflow
  alias BillingCore.ERP.{ErpDocument, FakeERP, SyncOperation}

  setup do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    ctx = credit_context_fixture()
    %{ctx: ctx, fake: fake}
  end

  test "freezes a zero-opening close with exact report, membership, and movement evidence", %{
    ctx: ctx
  } do
    policy = policy_fixture(ctx.scope, ctx.team.id)
    grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 12_345})

    assert {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))

    assert close.state == :ready
    assert close.opening_minor == 0
    assert close.closing_minor == 12_345
    assert close.net_change_minor == 12_345
    assert close.economic_liability_line_minor == -12_345
    assert close.ledger_transaction_count == 1
    assert close.report_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    assert [%TransactionMembership{transaction_id: transaction_id, ledger_ordinal: 1}] =
             Repo.all(
               from membership in TransactionMembership,
                 where: membership.close_id == ^close.id,
                 order_by: membership.ledger_ordinal
             )

    assert transaction_id == grant_transaction_id(grant.id)

    assert [
             %Movement{
               movement_type: :grant,
               amount_minor: 12_345,
               liability_effect_minor: 12_345,
               transaction_count: 1
             }
           ] =
             Repo.all(from(movement in Movement, where: movement.close_id == ^close.id))

    assert [:canonical_json, :csv_detail, :manifest, :pdf_summary] ==
             Repo.all(
               from evidence in Evidence,
                 where: evidence.close_id == ^close.id,
                 select: evidence.evidence_type,
                 order_by: evidence.evidence_type
             )

    assert {:ok, report} = CloseWorkflow.report(ctx.scope, close.id, :pdf_summary)
    assert report.sha256 != close.report_sha256
    assert String.starts_with?(report.bytes, "%PDF-")

    # Once ready, PostgreSQL—not just the command layer—guards every
    # financially significant close snapshot and its membership evidence.
    assert_raise Postgrex.Error, ~r/financial snapshot is immutable/, fn ->
      Repo.query!(
        "UPDATE billing.customer_credit_closes SET closing_minor = 1 WHERE id = $1",
        [Ecto.UUID.dump!(close.id)]
      )
    end

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.query!(
        "UPDATE billing.credit_close_transaction_memberships SET ledger_ordinal = 2 " <>
          "WHERE close_id = $1 AND transaction_id = $2",
        [Ecto.UUID.dump!(close.id), Ecto.UUID.dump!(transaction_id)]
      )
    end
  end

  test "approves, posts, attaches, reconciles, and closes a non-zero close", %{
    ctx: ctx,
    fake: fake
  } do
    connection = active_fake_connection(ctx.scope)
    policy = policy_fixture(ctx.scope, ctx.team.id)
    _grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 8_000})
    {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))

    assert {:ok, approved} =
             CloseWorkflow.approve(ctx.scope, close, reason: "monthly finance review")

    assert approved.state == :approved

    assert [%Approval{action: :approved, close_hash: hash, reason: "monthly finance review"}] =
             Repo.all(from approval in Approval, where: approval.close_id == ^close.id)

    assert hash == close.report_sha256
    assert {:ok, operation} = CloseWorkflow.request_posting(ctx.scope, approved)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    close = Repo.get!(CreditClose, close.id)
    operation = Operations.get!(operation.id)
    document = Repo.get_by!(ErpDocument, customer_credit_close_id: close.id)
    sync = Repo.get_by!(SyncOperation, operation_id: operation.id)

    assert close.state == :reconciled
    assert operation.state == "succeeded"
    assert document.state == "reconciled"
    assert sync.state == "succeeded"
    assert sync.response_metadata["attachment_sha256"]

    assert [voucher] = FakeERP.list_finance_vouchers(fake)
    assert voucher.external_reference == CloseWorkflow.external_reference(close)
    assert voucher.external_voucher_number == document.external_voucher_number

    assert {:ok, attachment} =
             FakeERP.get_voucher_attachment(
               FakeERP.connection_context(fake),
               {:voucher, voucher.external_voucher_number}
             )

    assert attachment.sha256 == sync.response_metadata["attachment_sha256"]

    assert [:erp_attachment, :erp_voucher, :reconciliation] ==
             Repo.all(
               from evidence in Evidence,
                 where:
                   evidence.close_id == ^close.id and
                     evidence.evidence_type in [:erp_attachment, :erp_voucher, :reconciliation],
                 select: evidence.evidence_type,
                 order_by: evidence.evidence_type
             )

    assert {:ok, closed} = CloseWorkflow.close_period(ctx.scope, close)
    assert closed.state == :closed
    assert %DateTime{} = closed.closed_at
    assert connection.status == "active"
  end

  test "recovers a lost voucher response without creating a duplicate", %{ctx: ctx, fake: fake} do
    _connection = active_fake_connection(ctx.scope)
    policy = policy_fixture(ctx.scope, ctx.team.id)
    _grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 7_000})
    {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))
    {:ok, approved} = CloseWorkflow.approve(ctx.scope, close)

    :ok = FakeERP.inject_unknown_outcome(fake, :create_finance_voucher)
    {:ok, operation} = CloseWorkflow.request_posting(ctx.scope, approved)

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    assert [_only_one] = FakeERP.list_finance_vouchers(fake)
    assert Operations.get!(operation.id).state == "succeeded"
    assert Repo.get!(CreditClose, close.id).state == :reconciled
    assert Repo.get_by!(SyncOperation, operation_id: operation.id).state == "succeeded"
  end

  test "a failed posting is retried through the close worker, never the invoice sync worker", %{
    ctx: ctx,
    fake: fake
  } do
    _connection = active_fake_connection(ctx.scope)
    policy = policy_fixture(ctx.scope, ctx.team.id)
    _grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 6_000})
    {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))
    {:ok, approved} = CloseWorkflow.approve(ctx.scope, close)

    :ok =
      FakeERP.inject_failure(
        fake,
        :create_finance_voucher,
        {:error, {:validation, %{field: "journal"}}}
      )

    {:ok, operation} = CloseWorkflow.request_posting(ctx.scope, approved)
    Oban.drain_queue(queue: :erp, with_safety: false)
    assert Operations.get!(operation.id).state == "failed"

    # BC-US-106 manual retry must route back into the close worker; the
    # invoice sync worker would crash on the voucher document.
    {:ok, _retried} =
      BillingCore.ERP.Sync.retry_operation(ctx.scope, Operations.get!(operation.id))

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    assert Operations.get!(operation.id).state == "succeeded"
    assert Repo.get!(CreditClose, close.id).state == :reconciled
    assert [_voucher] = FakeERP.list_finance_vouchers(fake)
  end

  test "zero-delta policy reconciles locally and never creates an ERP voucher", %{
    ctx: ctx,
    fake: fake
  } do
    _connection = active_fake_connection(ctx.scope)
    policy = policy_fixture(ctx.scope, ctx.team.id, post_zero_delta: false)
    {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))
    {:ok, approved} = CloseWorkflow.approve(ctx.scope, close)

    assert {:ok, operation} = CloseWorkflow.request_posting(ctx.scope, approved)
    assert Operations.get!(operation.id).state == "succeeded"
    assert Repo.get!(CreditClose, close.id).state == :reconciled
    assert FakeERP.list_finance_vouchers(fake) == []
    assert Repo.get_by(ErpDocument, customer_credit_close_id: close.id) == nil
    assert Repo.get_by(SyncOperation, operation_id: operation.id) == nil
  end

  test "a reversal/replacement corrects an accepted close without touching frozen history", %{
    ctx: ctx,
    fake: fake
  } do
    _connection = active_fake_connection(ctx.scope)
    wrong_policy = policy_fixture(ctx.scope, ctx.team.id)
    grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 9_000})

    # Post and accept the month under the (later discovered wrong) policy.
    {:ok, original} = CloseWorkflow.generate(ctx.scope, close_attrs(wrong_policy))
    {:ok, _} = CloseWorkflow.approve(ctx.scope, original)
    {:ok, _} = CloseWorkflow.request_posting(ctx.scope, original)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _} = CloseWorkflow.close_period(ctx.scope, original)

    # Reversal requires an explicit reason and an accepted close.
    assert {:error, :correction_reason_required} =
             CloseWorkflow.request_reversal(ctx.scope, original)

    assert {:ok, reversal} =
             CloseWorkflow.request_reversal(ctx.scope, original,
               reason: "liability account mis-configured"
             )

    assert reversal.close_kind == :reversal
    assert reversal.state == :ready
    assert reversal.reversal_of_close_id == original.id
    # The mirrored bridge: opening/closing swapped, deltas negated.
    assert reversal.opening_minor == 9_000
    assert reversal.closing_minor == 0
    assert reversal.net_change_minor == -9_000
    assert reversal.economic_liability_line_minor == 9_000
    assert Repo.get!(CreditClose, original.id).state == :reversal_pending

    # The reversal voucher posts through the ordinary flow and terminally
    # reverses the original when it reconciles.
    {:ok, _} = CloseWorkflow.approve(ctx.scope, reversal, reason: "reversal review")
    {:ok, _} = CloseWorkflow.request_posting(ctx.scope, reversal)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    assert Repo.get!(CreditClose, reversal.id).state == :reconciled
    assert Repo.get!(CreditClose, original.id).state == :reversed
    {:ok, _} = CloseWorkflow.close_period(ctx.scope, reversal)

    # Two vouchers exist: the wrong one and its exact negation.
    vouchers = FakeERP.list_finance_vouchers(fake)
    assert length(vouchers) == 2

    # A reversed period without a replacement blocks the next month.
    next_start = Date.add(Date.end_of_month(month_start()), 1)

    assert {:error, {:previous_close_reversed, _id}} =
             CloseWorkflow.generate(ctx.scope, %{
               currency: "DKK",
               period_start: next_start,
               period_end_exclusive: Date.add(Date.end_of_month(next_start), 1),
               transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
               policy_version_id: wrong_policy.id,
               bootstrap_opening_minor: 0
             })

    # The replacement reproduces the exact frozen figures under the
    # corrected policy, recomputed from the immutable membership.
    corrected_policy = policy_fixture(ctx.scope, ctx.team.id)

    assert {:ok, replacement} =
             CloseWorkflow.generate_replacement(ctx.scope, original,
               policy_version_id: corrected_policy.id,
               reason: "repost under corrected accounts"
             )

    assert replacement.close_kind == :replacement
    assert replacement.state == :ready
    assert replacement.opening_minor == original.opening_minor
    assert replacement.closing_minor == original.closing_minor
    assert replacement.ledger_snapshot_hash == original.ledger_snapshot_hash
    assert replacement.policy_version_id == corrected_policy.id
    # Membership stays exactly on the original close.
    assert Repo.aggregate(
             from(m in TransactionMembership, where: m.close_id == ^replacement.id),
             :count
           ) == 0

    assert [%TransactionMembership{}] =
             Repo.all(from m in TransactionMembership, where: m.close_id == ^original.id)

    assert grant_transaction_id(grant.id)

    {:ok, _} = CloseWorkflow.approve(ctx.scope, replacement, reason: "replacement review")
    {:ok, _} = CloseWorkflow.request_posting(ctx.scope, replacement)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, accepted} = CloseWorkflow.close_period(ctx.scope, replacement)
    assert accepted.state == :closed

    # A second replacement for the same period is rejected.
    assert {:error, {:already_exists, _id}} =
             CloseWorkflow.generate_replacement(ctx.scope, original,
               policy_version_id: corrected_policy.id,
               reason: "duplicate"
             )

    # Continuity resumes through the replacement: the next month opens at
    # the replacement's closing balance.
    assert {:ok, next_close} =
             CloseWorkflow.generate(ctx.scope, %{
               currency: "DKK",
               period_start: next_start,
               period_end_exclusive: Date.add(Date.end_of_month(next_start), 1),
               transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
               policy_version_id: corrected_policy.id,
               bootstrap_opening_minor: 0
             })

    assert next_close.opening_minor == 9_000
    assert next_close.previous_close_id == replacement.id
  end

  test "a missed prior-period transaction blocks the next close until explicitly approved", %{
    ctx: ctx
  } do
    _connection = active_fake_connection(ctx.scope)
    policy = policy_fixture(ctx.scope, ctx.team.id)
    _grant = grant_fixture(ctx.scope, ctx.credit_account, %{amount_minor: 5_000})

    {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))
    {:ok, _} = CloseWorkflow.approve(ctx.scope, close)
    {:ok, _} = CloseWorkflow.request_posting(ctx.scope, close)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _} = CloseWorkflow.close_period(ctx.scope, close)

    # Simulate the commit race the guard defends: a consistent ledger entry
    # whose occurred_at predates the accepted close's cutoff. Transactions
    # are append-only, so this is inserted with its late values directly.
    missed = missed_grant!(ctx, 2_000, DateTime.add(close.transaction_cutoff, -1, :second))

    next_start = Date.add(Date.end_of_month(month_start()), 1)

    next_attrs = %{
      currency: "DKK",
      period_start: next_start,
      period_end_exclusive: Date.add(Date.end_of_month(next_start), 1),
      transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
      policy_version_id: policy.id,
      bootstrap_opening_minor: 0
    }

    # Silent inclusion is refused (BC-US-165).
    assert {:error, {:missed_prior_transaction, missed_id}} =
             CloseWorkflow.generate(ctx.scope, next_attrs)

    assert missed_id == missed.id

    # Explicit approval routes it into the current period as a
    # prior-period adjustment.
    assert {:ok, next_close} =
             CloseWorkflow.generate(
               ctx.scope,
               Map.put(next_attrs, :approved_prior_period_transaction_ids, [missed.id])
             )

    assert next_close.opening_minor == 5_000
    assert next_close.closing_minor == 7_000

    assert %Movement{
             movement_type: :prior_period_adjustment,
             amount_minor: 2_000,
             liability_effect_minor: 2_000,
             transaction_count: 1
           } =
             Repo.one!(
               from movement in Movement,
                 where:
                   movement.close_id == ^next_close.id and
                     movement.movement_type == :prior_period_adjustment
             )

    # The transaction is now membered exactly once, in the current period.
    assert Repo.one!(
             from membership in TransactionMembership,
               where: membership.transaction_id == ^missed.id,
               select: membership.close_id
           ) == next_close.id
  end

  defp missed_grant!(ctx, amount, occurred_at) do
    account = Repo.get!(BillingCore.Credits.CreditAccount, ctx.credit_account.id)
    effective_on = DateTime.to_date(occurred_at)

    grant =
      Repo.insert!(%BillingCore.Credits.CreditGrant{
        team_id: account.team_id,
        credit_account_id: account.id,
        origin_type: "manual",
        granted_minor: amount,
        currency: account.currency,
        granted_at: occurred_at,
        status: :available,
        remaining_minor: amount
      })

    transaction =
      Repo.insert!(%BillingCore.Credits.CreditTransaction{
        team_id: account.team_id,
        credit_account_id: account.id,
        grant_id: grant.id,
        transaction_type: :grant,
        amount_minor: amount,
        currency: account.currency,
        idempotency_key: "missed-#{System.unique_integer([:positive])}",
        accounting_effective_on: effective_on,
        occurred_at: occurred_at,
        metadata: %{}
      })

    account
    |> Ecto.Changeset.change(available_minor: account.available_minor + amount)
    |> Repo.update!()

    transaction
  end

  test "a finance role from another team cannot read, approve, or post the close", %{ctx: ctx} do
    policy = policy_fixture(ctx.scope, ctx.team.id)
    {:ok, close} = CloseWorkflow.generate(ctx.scope, close_attrs(policy))
    other = credit_context_fixture()

    assert {:error, :not_found} = CloseWorkflow.report(other.scope, close.id, :pdf_summary)
    assert {:error, :not_found} = CloseWorkflow.approve(other.scope, close)
    assert {:error, :not_found} = CloseWorkflow.request_posting(other.scope, close)
  end

  defp active_fake_connection(scope) do
    assert {:ok, connection} =
             ERP.create_connection(scope, %{provider: "fake", secret_reference: "x"})

    assert {:ok, connection} = ERP.validate_connection(scope, connection)
    connection
  end

  defp policy_fixture(scope, team_id, opts \\ []) do
    assert {:ok, policy} =
             CloseKernel.create_policy(scope, %{
               version: System.unique_integer([:positive]),
               effective_from: month_start(),
               journal_number: 1,
               liability_account_number: 2990,
               posting_mode: :single_offset,
               default_offset_account_number: 5890,
               post_zero_delta: Keyword.get(opts, :post_zero_delta, false),
               vat_neutral: true,
               created_by: scope.user.id
             })

    assert policy.team_id == team_id
    policy
  end

  defp close_attrs(policy) do
    %{
      currency: "DKK",
      period_start: month_start(),
      period_end_exclusive: Date.add(Date.end_of_month(month_start()), 1),
      transaction_cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
      policy_version_id: policy.id,
      bootstrap_opening_minor: 0
    }
  end

  defp month_start, do: Date.beginning_of_month(Date.utc_today())

  defp grant_transaction_id(grant_id) do
    Repo.one!(
      from transaction in BillingCore.Credits.CreditTransaction,
        where: transaction.grant_id == ^grant_id,
        select: transaction.id
    )
  end
end
