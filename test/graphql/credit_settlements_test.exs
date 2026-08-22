defmodule BillingCoreWeb.GraphQL.CreditSettlementsTest do
  @moduledoc """
  SPEC §9.4.1 receivable-settlement surface: the policy declares the mode,
  settlements are team-scoped finance reads, and the external reference is
  recorded exactly once through a typed mutation.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  alias BillingCore.Repo

  setup %{conn: conn} do
    ctx = register_actor([:team_admin, :billing_admin, :finance_operator])
    %{conn: conn, ctx: ctx}
  end

  @create_policy """
  mutation CreatePolicy($input: CreateCreditClosePolicyInput!) {
    createCreditClosePolicy(input: $input) {
      __typename
      ... on CreateCreditClosePolicySuccess {
        policy { id settlementMode settlementClearingAccountNumber }
      }
      ... on ValidationProblem { code fields { path code } }
      ... on AuthorizationProblem { code }
    }
  }
  """

  test "the policy carries the certified settlement mode", %{conn: conn, ctx: ctx} do
    {200, %{"data" => %{"createCreditClosePolicy" => payload}}} =
      gql(conn, @create_policy,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "effectiveFrom" => "2026-08-01",
            "journalNumber" => 1,
            "liabilityAccountNumber" => 2990,
            "defaultOffsetAccountNumber" => 5890,
            "settlementMode" => "erp_customer_settlement",
            "settlementClearingAccountNumber" => 5820,
            "settlementContraAccountNumber" => 5821,
            "clientMutationId" => "policy-1"
          }
        }
      )

    assert payload["policy"]["settlementMode"] == "erp_customer_settlement"
    assert payload["policy"]["settlementClearingAccountNumber"] == 5820
  end

  test "erp mode without clearing accounts is a typed validation problem", %{conn: conn, ctx: ctx} do
    {200, %{"data" => %{"createCreditClosePolicy" => payload}}} =
      gql(conn, @create_policy,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "effectiveFrom" => "2026-08-01",
            "journalNumber" => 1,
            "liabilityAccountNumber" => 2990,
            "defaultOffsetAccountNumber" => 5890,
            "settlementMode" => "erp_customer_settlement",
            "clientMutationId" => "policy-2"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
  end

  test "settlements list and external-reference reconciliation", %{conn: conn, ctx: ctx} do
    policy = BillingCore.CreditsFixtures.settlement_policy_fixture(ctx.scope)

    account = BillingCore.OrgsFixtures.account_fixture(ctx.organization)

    {:ok, credit_account} =
      BillingCore.Credits.get_or_create_account(ctx.scope, account.id, "DKK")

    # A pending settlement as the freeze transaction would record it.
    {:ok, settlement} =
      Repo.transaction(fn ->
        intent_id = insert_minimal_intent!(ctx)

        BillingCore.Credits.Settlements.record_application!(
          ctx.scope,
          intent_id,
          credit_account,
          15_000,
          "DKK"
        )
      end)

    assert settlement.policy_version_id == policy.id

    query = """
    query Settlements($teamId: ID!, $state: String) {
      creditSettlements(teamId: $teamId, state: $state) {
        id mode state amountMinor currency externalReference
      }
    }
    """

    {200, %{"data" => %{"creditSettlements" => [listed]}}} =
      gql(conn, query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "state" => "pending"}
      )

    assert listed["id"] == settlement.id
    assert listed["mode"] == "external_reference"
    assert listed["amountMinor"] == 15_000

    mutation = """
    mutation Record($input: RecordExternalSettlementInput!) {
      recordExternalSettlement(input: $input) {
        __typename
        ... on RecordExternalSettlementSuccess {
          settlement { state externalReference }
        }
        ... on ValidationProblem { code }
        ... on AuthorizationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"recordExternalSettlement" => recorded}}} =
      gql(conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "settlementId" => settlement.id,
            "externalReference" => "remit-42",
            "clientMutationId" => "settle-1"
          }
        }
      )

    assert recorded["settlement"] == %{"state" => "reconciled", "externalReference" => "remit-42"}

    # A conflicting second reference is a typed problem, not a mutation.
    {200, %{"data" => %{"recordExternalSettlement" => conflicted}}} =
      gql(conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "settlementId" => settlement.id,
            "externalReference" => "remit-43",
            "clientMutationId" => "settle-2"
          }
        }
      )

    assert conflicted["__typename"] == "ValidationProblem"
    assert conflicted["code"] == "ALREADY_RECONCILED"

    # Cross-team denial: another team's scope sees nothing.
    outsider = register_actor([:finance_operator])

    {200, %{"data" => %{"creditSettlements" => []}}} =
      gql(conn, query, token: outsider.token, variables: %{"teamId" => outsider.team.id})
  end

  # The settlement references an invoice intent row; the surface test only
  # needs its identity, not a full billing flow (covered in workflows).
  defp insert_minimal_intent!(ctx) do
    customer = BillingCore.ContractsFixtures.customer_fixture(ctx.scope)

    {:ok, preview_intent} =
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        chain = Repo.insert!(%BillingCore.Billing.InvoiceChain{team_id: ctx.team.id})

        Repo.insert!(%BillingCore.Billing.InvoiceIntent{
          id: Ecto.UUID.generate(),
          team_id: ctx.team.id,
          invoice_chain_id: chain.id,
          customer_id: customer.id,
          customer_version: 1,
          currency: "DKK",
          invoice_date: Date.utc_today(),
          intent_version: 1,
          document_kind: "invoice",
          canonical_snapshot: %{},
          content_hash: "test",
          net_amount_minor: 15_000,
          created_at: now,
          frozen_at: now
        })
      end)

    preview_intent.id
  end
end
