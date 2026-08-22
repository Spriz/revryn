defmodule BillingCoreWeb.GraphQL.CreditsTest do
  @moduledoc """
  Customer-credit subledger over the public API (BC-US-107): grant credit
  with idempotent replay, inspect accounts/grants/transactions, typed
  validation problems, and cross-team denial.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  alias BillingCore.{Credits, Orgs}

  setup %{conn: conn} do
    ctx = register_actor([:team_admin, :billing_admin, :finance_operator])

    customer = customer_fixture(ctx.scope)
    account = account_fixture(ctx.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, ctx.team, customer.id)
    {:ok, credit_account} = Credits.get_or_create_account(ctx.scope, account.id, "DKK")

    Map.merge(ctx, %{conn: conn, customer: customer, credit_account: credit_account})
  end

  @grant_mutation """
  mutation Grant($input: GrantCreditInput!) {
    grantCredit(input: $input) {
      __typename
      ... on GrantCreditSuccess {
        creditGrant { id originType grantedMinor remainingMinor currency status }
      }
      ... on ValidationProblem { code message }
    }
  }
  """

  defp grant!(ctx, input_overrides) do
    input =
      Map.merge(
        %{
          "teamId" => ctx.team.id,
          "creditAccountId" => ctx.credit_account.id,
          "originType" => "goodwill",
          "amountMinor" => 12_500,
          "currency" => "DKK",
          "reasonCode" => "api_goodwill",
          "idempotencyKey" => "grant-1",
          "clientMutationId" => "g1"
        },
        input_overrides
      )

    {200, %{"data" => %{"grantCredit" => payload}}} =
      gql(ctx.conn, @grant_mutation, token: ctx.token, variables: %{"input" => input})

    payload
  end

  test "grants credit, replays idempotently, and exposes the subledger", ctx do
    payload = grant!(ctx, %{})
    assert %{"__typename" => "GrantCreditSuccess", "creditGrant" => grant} = payload
    assert grant["originType"] == "goodwill"
    assert grant["grantedMinor"] == 12_500
    assert grant["remainingMinor"] == 12_500
    assert grant["status"] == "available"

    # Replaying the same idempotency key returns the same grant.
    replay = grant!(ctx, %{})
    assert replay["creditGrant"]["id"] == grant["id"]

    query = """
    query Accounts($teamId: ID!, $customerId: ID!) {
      creditAccounts(teamId: $teamId, customerId: $customerId) {
        id currency availableMinor reservedMinor
        grants { id originType remainingMinor }
        transactions { transactionType amountMinor reasonCode }
      }
    }
    """

    {200, %{"data" => %{"creditAccounts" => [credit_account]}}} =
      gql(ctx.conn, query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "customerId" => ctx.customer.id}
      )

    assert credit_account["availableMinor"] == 12_500
    assert credit_account["reservedMinor"] == 0
    assert [%{"id" => grant_id}] = credit_account["grants"]
    assert grant_id == grant["id"]

    assert [
             %{
               "transactionType" => "grant",
               "amountMinor" => 12_500,
               "reasonCode" => "api_goodwill"
             }
           ] =
             credit_account["transactions"]
  end

  test "sets and reads the versioned disposition policy (BC-US-109)", ctx do
    mutation = """
    mutation SetPolicy($input: SetCreditDispositionPolicyInput!) {
      setCreditDispositionPolicy(input: $input) {
        __typename
        ... on SetCreditDispositionPolicySuccess {
          dispositionPolicy { version policy expireAfterDays }
        }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"setCreditDispositionPolicy" => payload}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditAccountId" => ctx.credit_account.id,
            "policy" => "expire_after",
            "expireAfterDays" => 90,
            "clientMutationId" => "policy-1"
          }
        }
      )

    assert %{"dispositionPolicy" => %{"version" => 1, "policy" => "expire_after"}} = payload

    # The account exposes the currently effective policy.
    query = """
    query Accounts($teamId: ID!, $customerId: ID!) {
      creditAccounts(teamId: $teamId, customerId: $customerId) {
        dispositionPolicy { version policy expireAfterDays }
      }
    }
    """

    {200, %{"data" => %{"creditAccounts" => [account]}}} =
      gql(ctx.conn, query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "customerId" => ctx.customer.id}
      )

    assert account["dispositionPolicy"]["policy"] == "expire_after"
    assert account["dispositionPolicy"]["expireAfterDays"] == 90

    # An unknown policy value is a typed validation problem, not an atom leak.
    {200, %{"data" => %{"setCreditDispositionPolicy" => bad}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditAccountId" => ctx.credit_account.id,
            "policy" => "delete_everything",
            "clientMutationId" => "policy-bad"
          }
        }
      )

    assert bad["__typename"] == "ValidationProblem"
  end

  test "an unknown origin type is a typed validation problem", ctx do
    payload = grant!(ctx, %{"originType" => "discount", "idempotencyKey" => "grant-bad"})
    assert payload["__typename"] == "ValidationProblem"
  end

  test "cross-team access is denied without leaking the account", ctx do
    grant!(ctx, %{})
    outsider = register_actor([:team_admin, :billing_admin, :finance_operator])

    query = """
    query Accounts($teamId: ID!, $customerId: ID!) {
      creditAccounts(teamId: $teamId, customerId: $customerId) { id }
    }
    """

    {200, body} =
      gql(ctx.conn, query,
        token: outsider.token,
        variables: %{"teamId" => ctx.team.id, "customerId" => ctx.customer.id}
      )

    assert body["data"]["creditAccounts"] == nil
    assert [%{"code" => "UNAUTHORIZED"} | _rest] = body["errors"]

    grant_payload = """
    mutation Grant($input: GrantCreditInput!) {
      grantCredit(input: $input) { __typename }
    }
    """

    {200, cross_body} =
      gql(ctx.conn, grant_payload,
        token: outsider.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditAccountId" => ctx.credit_account.id,
            "originType" => "goodwill",
            "amountMinor" => 100,
            "currency" => "DKK",
            "idempotencyKey" => "cross-1",
            "clientMutationId" => "cross"
          }
        }
      )

    refute get_in(cross_body, ["data", "grantCredit", "__typename"]) == "GrantCreditSuccess"
  end
end
