defmodule BillingCoreWeb.GraphQL.CreditClosesTest do
  @moduledoc """
  Monthly customer-credit close over the public API (BC-TASK-104): policy
  setup → deterministic generation → approval → durable posting →
  reconciliation → period close, plus report access, idempotent replay, and
  cross-team denial — the same domain commands as the LiveView surface.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  import BillingCore.CreditsFixtures, only: [grant_fixture: 3]

  alias BillingCore.{Credits, ERP, Orgs}
  alias BillingCore.ERP.FakeERP

  setup %{conn: conn} do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    ctx = register_actor([:team_admin, :billing_admin, :finance_operator])

    {:ok, connection} =
      ERP.create_connection(ctx.scope, %{provider: "fake", secret_reference: "unused"})

    {:ok, _connection} = ERP.validate_connection(ctx.scope, connection)

    customer = customer_fixture(ctx.scope)
    account = account_fixture(ctx.organization)
    {:ok, _projection} = Orgs.project_account_to_team(account, ctx.team, customer.id)
    {:ok, credit_account} = Credits.get_or_create_account(ctx.scope, account.id, "DKK")
    grant_fixture(ctx.scope, credit_account, %{amount_minor: 9_000})

    Map.merge(ctx, %{conn: conn, fake: fake})
  end

  defp create_policy!(ctx) do
    mutation = """
    mutation CreatePolicy($input: CreateCreditClosePolicyInput!) {
      createCreditClosePolicy(input: $input) {
        __typename
        ... on CreateCreditClosePolicySuccess {
          policy { id version journalNumber liabilityAccountNumber postingMode }
        }
      }
    }
    """

    {200, %{"data" => %{"createCreditClosePolicy" => payload}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "effectiveFrom" => Date.to_iso8601(Date.beginning_of_month(Date.utc_today())),
            "journalNumber" => 1,
            "liabilityAccountNumber" => 2990,
            "defaultOffsetAccountNumber" => 5890,
            "clientMutationId" => "policy-1"
          }
        }
      )

    assert %{"__typename" => "CreateCreditClosePolicySuccess", "policy" => policy} = payload
    policy
  end

  defp generate!(ctx, idempotency_key) do
    mutation = """
    mutation Generate($input: GenerateCreditCloseInput!) {
      generateCreditClose(input: $input) {
        __typename
        ... on GenerateCreditCloseSuccess {
          creditClose {
            id state currency openingMinor closingMinor netChangeMinor
            reportSha256
            movements { movementType amountMinor transactionCount }
            evidence { evidenceType sha256 contentType byteSize }
          }
        }
        ... on IdempotencyConflict { code }
      }
    }
    """

    {200, %{"data" => %{"generateCreditClose" => payload}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "currency" => "DKK",
            "periodDate" => Date.to_iso8601(Date.utc_today()),
            "bootstrapOpeningMinor" => 0,
            "idempotencyKey" => idempotency_key,
            "clientMutationId" => "generate-1"
          }
        }
      )

    payload
  end

  test "policy → generate → approve → post → reconcile → close, with report access", ctx do
    policy = create_policy!(ctx)
    assert policy["version"] == 1
    assert policy["postingMode"] == "single_offset"

    payload = generate!(ctx, "gen-1")
    assert %{"__typename" => "GenerateCreditCloseSuccess", "creditClose" => close} = payload
    assert close["state"] == "ready"
    assert close["openingMinor"] == 0
    assert close["closingMinor"] == 9_000
    assert [%{"movementType" => "grant", "amountMinor" => 9_000}] = close["movements"]
    assert Enum.any?(close["evidence"], &(&1["evidenceType"] == "pdf_summary"))

    # Idempotent replay converges on the same close.
    replay = generate!(ctx, "gen-1")
    assert %{"creditClose" => %{"id" => replay_id}} = replay
    assert replay_id == close["id"]

    # Report access returns the exact stored bytes.
    report_query = """
    query Report($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) {
        report(evidenceType: "pdf_summary") { sha256 contentType contentBase64 }
      }
    }
    """

    {200, %{"data" => %{"creditClose" => %{"report" => report}}}} =
      gql(ctx.conn, report_query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    assert report["contentType"] == "application/pdf"
    assert report["contentBase64"] |> Base.decode64!() |> String.starts_with?("%PDF-")

    # Approve the exact report hash.
    approve = """
    mutation Approve($input: ApproveCreditCloseInput!) {
      approveCreditClose(input: $input) {
        __typename
        ... on ApproveCreditCloseSuccess { creditClose { state } }
      }
    }
    """

    {200, %{"data" => %{"approveCreditClose" => approve_payload}}} =
      gql(ctx.conn, approve,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "reason" => "monthly api review",
            "clientMutationId" => "approve-1"
          }
        }
      )

    assert %{"creditClose" => %{"state" => "approved"}} = approve_payload

    # Durable posting: operation is queued, then the worker reconciles.
    post = """
    mutation Post($input: RequestCreditClosePostingInput!) {
      requestCreditClosePosting(input: $input) {
        __typename
        ... on RequestCreditClosePostingSuccess {
          operation { id state type }
          creditClose { state }
        }
      }
    }
    """

    {200, %{"data" => %{"requestCreditClosePosting" => post_payload}}} =
      gql(ctx.conn, post,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "idempotencyKey" => "post-1",
            "clientMutationId" => "post-1"
          }
        }
      )

    assert %{"operation" => %{"type" => "erp.post_customer_credit_close"}} = post_payload
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    status_query = """
    query Close($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) { state externalVoucherNumber }
    }
    """

    {200, %{"data" => %{"creditClose" => reconciled}}} =
      gql(ctx.conn, status_query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    assert reconciled["state"] == "reconciled"
    assert reconciled["externalVoucherNumber"]

    # Accept the period.
    close_period = """
    mutation ClosePeriod($input: CloseCreditPeriodInput!) {
      closeCreditPeriod(input: $input) {
        __typename
        ... on CloseCreditPeriodSuccess { creditClose { state closedAt } }
      }
    }
    """

    {200, %{"data" => %{"closeCreditPeriod" => closed_payload}}} =
      gql(ctx.conn, close_period,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "clientMutationId" => "close-1"
          }
        }
      )

    assert %{"creditClose" => %{"state" => "closed", "closedAt" => closed_at}} = closed_payload
    assert is_binary(closed_at)
  end

  test "reversal and replacement corrections run over the public API", ctx do
    create_policy!(ctx)
    %{"creditClose" => close} = generate!(ctx, "gen-correction")

    # Drive to accepted through the API commands already covered above.
    for {mutation, field, input} <- [
          {"mutation A($input: ApproveCreditCloseInput!) { approveCreditClose(input: $input) { __typename } }",
           "approveCreditClose",
           %{"teamId" => ctx.team.id, "creditCloseId" => close["id"], "clientMutationId" => "a"}},
          {"mutation P($input: RequestCreditClosePostingInput!) { requestCreditClosePosting(input: $input) { __typename } }",
           "requestCreditClosePosting",
           %{
             "teamId" => ctx.team.id,
             "creditCloseId" => close["id"],
             "idempotencyKey" => "post-corr",
             "clientMutationId" => "p"
           }}
        ] do
      {200, %{"data" => %{^field => %{"__typename" => typename}}}} =
        gql(ctx.conn, mutation, token: ctx.token, variables: %{"input" => input})

      assert typename =~ "Success"
    end

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    close_period = """
    mutation C($input: CloseCreditPeriodInput!) {
      closeCreditPeriod(input: $input) { __typename }
    }
    """

    {200, _body} =
      gql(ctx.conn, close_period,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "clientMutationId" => "c"
          }
        }
      )

    # Reversal freezes the mirrored bridge.
    reversal_mutation = """
    mutation R($input: RequestCreditCloseReversalInput!) {
      requestCreditCloseReversal(input: $input) {
        __typename
        ... on RequestCreditCloseReversalSuccess {
          reversalClose {
            id state closeKind reversalOfCloseId openingMinor closingMinor netChangeMinor
          }
        }
        ... on ValidationProblem { code message }
      }
    }
    """

    {200, %{"data" => %{"requestCreditCloseReversal" => reversal_payload}}} =
      gql(ctx.conn, reversal_mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "reason" => "wrong liability account",
            "clientMutationId" => "r"
          }
        }
      )

    assert %{"reversalClose" => reversal} = reversal_payload
    assert reversal["closeKind"] == "reversal"
    assert reversal["reversalOfCloseId"] == close["id"]
    assert reversal["openingMinor"] == 9_000
    assert reversal["closingMinor"] == 0
    assert reversal["netChangeMinor"] == -9_000

    # The original exposes its corrections and reversal_pending state.
    status_query = """
    query S($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) {
        state closeKind
        corrections { id closeKind state }
      }
    }
    """

    {200, %{"data" => %{"creditClose" => original}}} =
      gql(ctx.conn, status_query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    assert original["state"] == "reversal_pending"
    assert [%{"closeKind" => "reversal"}] = original["corrections"]

    # A replacement before the reversal reconciles is rejected with a
    # typed problem, not a crash.
    replacement_mutation = """
    mutation Rep($input: GenerateCreditCloseReplacementInput!) {
      generateCreditCloseReplacement(input: $input) {
        __typename
        ... on GenerateCreditCloseReplacementSuccess {
          replacementClose { id closeKind state closingMinor }
        }
        ... on ValidationProblem { code }
      }
    }
    """

    policy_query = """
    query P($teamId: ID!) { creditClosePolicies(teamId: $teamId) { id } }
    """

    {200, %{"data" => %{"creditClosePolicies" => [%{"id" => policy_id} | _]}}} =
      gql(ctx.conn, policy_query, token: ctx.token, variables: %{"teamId" => ctx.team.id})

    replacement_input = %{
      "teamId" => ctx.team.id,
      "creditCloseId" => close["id"],
      "policyVersionId" => policy_id,
      "reason" => "repost corrected",
      "clientMutationId" => "rep"
    }

    {200, %{"data" => %{"generateCreditCloseReplacement" => early}}} =
      gql(ctx.conn, replacement_mutation,
        token: ctx.token,
        variables: %{"input" => replacement_input}
      )

    assert early["__typename"] == "ValidationProblem"

    # Reconcile the reversal voucher; the original becomes reversed and the
    # replacement then succeeds with the exact original figures.
    approve = """
    mutation A($input: ApproveCreditCloseInput!) { approveCreditClose(input: $input) { __typename } }
    """

    {200, _} =
      gql(ctx.conn, approve,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => reversal["id"],
            "clientMutationId" => "ra"
          }
        }
      )

    post = """
    mutation P($input: RequestCreditClosePostingInput!) { requestCreditClosePosting(input: $input) { __typename } }
    """

    {200, _} =
      gql(ctx.conn, post,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => reversal["id"],
            "idempotencyKey" => "post-reversal",
            "clientMutationId" => "rp"
          }
        }
      )

    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    {200, %{"data" => %{"creditClose" => reversed}}} =
      gql(ctx.conn, status_query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    assert reversed["state"] == "reversed"

    {200, %{"data" => %{"generateCreditCloseReplacement" => replacement_payload}}} =
      gql(ctx.conn, replacement_mutation,
        token: ctx.token,
        variables: %{"input" => replacement_input}
      )

    assert %{"replacementClose" => replacement} = replacement_payload
    assert replacement["closeKind"] == "replacement"
    assert replacement["state"] == "ready"
    assert replacement["closingMinor"] == 9_000
  end

  # Not covered on purpose in the CreditCloses resolvers: the listing/report
  # `:unauthorized` branches (every canonical team role has close read
  # access), the `stringify` nil guard (all stringified columns are
  # non-null for rows the API can create), the `actor_user_id` non-user
  # fallback (HTTP scopes always carry a user), and the
  # `safe_get_operation` rescue (posting outcomes always reference a live
  # operation row).

  test "creditCloses lists with state and currency filters; lookups miss safely", ctx do
    create_policy!(ctx)
    %{"creditClose" => close} = generate!(ctx, "gen-list")

    listing = """
    query Closes($teamId: ID!, $state: String, $currency: String) {
      creditCloses(teamId: $teamId, state: $state, currency: $currency) { id state currency }
    }
    """

    {200, %{"data" => %{"creditCloses" => ready}}} =
      gql(ctx.conn, listing,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "state" => "ready", "currency" => "DKK"}
      )

    assert Enum.map(ready, & &1["id"]) == [close["id"]]

    {200, %{"data" => %{"creditCloses" => closed}}} =
      gql(ctx.conn, listing,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "state" => "closed"}
      )

    assert closed == []

    lookup = """
    query Close($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) { id }
    }
    """

    for bad_id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      {200, body} =
        gql(ctx.conn, lookup,
          token: ctx.token,
          variables: %{"teamId" => ctx.team.id, "id" => bad_id}
        )

      assert body["data"]["creditClose"] == nil
      assert [%{"code" => "NOT_FOUND"} | _] = body["errors"]
    end
  end

  test "a ready close has no voucher yet; report misses are typed or null", ctx do
    create_policy!(ctx)
    %{"creditClose" => close} = generate!(ctx, "gen-report-miss")

    # Voucher number resolves to null until the posting reconciles, and a
    # valid-but-absent evidence type resolves to a null report without an
    # error entry.
    absent_report = """
    query Close($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) {
        externalVoucherNumber
        report(evidenceType: "reconciliation") { sha256 }
      }
    }
    """

    {200, body} =
      gql(ctx.conn, absent_report,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    refute body["errors"]
    assert body["data"]["creditClose"]["externalVoucherNumber"] == nil
    assert body["data"]["creditClose"]["report"] == nil

    # An evidence type outside the canonical set is NOT_FOUND.
    unknown_report = """
    query Close($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) {
        report(evidenceType: "hogwash") { sha256 }
      }
    }
    """

    {200, unknown_body} =
      gql(ctx.conn, unknown_report,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    assert [%{"code" => "NOT_FOUND"} | _] = unknown_body["errors"]
  end

  test "policy versions increment; invalid settlement modes are typed", ctx do
    first = create_policy!(ctx)
    assert first["version"] == 1

    second = create_policy!(ctx)
    assert second["version"] == 2

    mutation = """
    mutation CreatePolicy($input: CreateCreditClosePolicyInput!) {
      createCreditClosePolicy(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"createCreditClosePolicy" => payload}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "effectiveFrom" => Date.to_iso8601(Date.beginning_of_month(Date.utc_today())),
            "journalNumber" => 1,
            "liabilityAccountNumber" => 2990,
            "defaultOffsetAccountNumber" => 5890,
            "settlementMode" => "carrier-pigeon",
            "clientMutationId" => "policy-bad-mode"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "INVALID_SETTLEMENT_MODE"
  end

  test "generation pins an explicit policy version and fails without any policy", ctx do
    policy = create_policy!(ctx)

    mutation = """
    mutation Generate($input: GenerateCreditCloseInput!) {
      generateCreditClose(input: $input) {
        __typename
        ... on GenerateCreditCloseSuccess { creditClose { id state } }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"generateCreditClose" => pinned}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "currency" => "DKK",
            "periodDate" => Date.to_iso8601(Date.utc_today()),
            "policyVersionId" => policy["id"],
            "bootstrapOpeningMinor" => 0,
            "idempotencyKey" => "gen-pinned",
            "clientMutationId" => "gen-pinned"
          }
        }
      )

    assert %{"__typename" => "GenerateCreditCloseSuccess"} = pinned

    # A team without a posting policy cannot generate at all.
    unpoliced = register_actor([:team_admin, :billing_admin, :finance_operator])

    {200, %{"data" => %{"generateCreditClose" => refused}}} =
      gql(ctx.conn, mutation,
        token: unpoliced.token,
        variables: %{
          "input" => %{
            "teamId" => unpoliced.team.id,
            "currency" => "DKK",
            "periodDate" => Date.to_iso8601(Date.utc_today()),
            "idempotencyKey" => "gen-unpoliced",
            "clientMutationId" => "gen-unpoliced"
          }
        }
      )

    assert refused["__typename"] == "ValidationProblem"
    assert refused["code"] == "CLOSE_POLICY_NOT_EFFECTIVE"
  end

  test "lifecycle commands out of order are typed problems, not crashes", ctx do
    create_policy!(ctx)
    %{"creditClose" => close} = generate!(ctx, "gen-out-of-order")

    approve = """
    mutation Approve($input: ApproveCreditCloseInput!) {
      approveCreditClose(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    # Approving a missing or malformed close ID is NOT_FOUND.
    for bad_id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      {200, %{"data" => %{"approveCreditClose" => payload}}} =
        gql(ctx.conn, approve,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "creditCloseId" => bad_id,
              "clientMutationId" => "approve-miss"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "NOT_FOUND"
    end

    # Posting a close that was never approved is refused by state.
    post = """
    mutation Post($input: RequestCreditClosePostingInput!) {
      requestCreditClosePosting(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"requestCreditClosePosting" => posted}}} =
      gql(ctx.conn, post,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "idempotencyKey" => "post-early",
            "clientMutationId" => "post-early"
          }
        }
      )

    assert posted["__typename"] == "ValidationProblem"
    assert posted["code"] == "INVALID_CLOSE_STATE"

    # Reversing a close that is not yet accepted is refused by state.
    reversal = """
    mutation Reverse($input: RequestCreditCloseReversalInput!) {
      requestCreditCloseReversal(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"requestCreditCloseReversal" => reversed}}} =
      gql(ctx.conn, reversal,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "reason" => "premature",
            "clientMutationId" => "reverse-early"
          }
        }
      )

    assert reversed["__typename"] == "ValidationProblem"
    assert reversed["code"] == "INVALID_CLOSE_STATE"

    # Accepting the period before reconciliation is an illegal transition.
    close_period = """
    mutation ClosePeriod($input: CloseCreditPeriodInput!) {
      closeCreditPeriod(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"closeCreditPeriod" => closed}}} =
      gql(ctx.conn, close_period,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "clientMutationId" => "close-early"
          }
        }
      )

    assert closed["__typename"] == "ValidationProblem"
    assert closed["code"] == "ILLEGAL_CLOSE_TRANSITION"
  end

  test "cross-team access is rejected without leaking the close", ctx do
    create_policy!(ctx)
    %{"creditClose" => close} = generate!(ctx, "gen-cross")

    outsider = register_actor([:team_admin, :billing_admin, :finance_operator])

    query = """
    query Close($teamId: ID!, $id: ID!) {
      creditClose(teamId: $teamId, id: $id) { id state }
    }
    """

    {200, body} =
      gql(ctx.conn, query,
        token: outsider.token,
        variables: %{"teamId" => ctx.team.id, "id" => close["id"]}
      )

    assert body["data"]["creditClose"] == nil
    assert [%{"code" => "UNAUTHORIZED"} | _rest] = body["errors"]

    # And a foreign-team mutation cannot approve it either.
    approve = """
    mutation Approve($input: ApproveCreditCloseInput!) {
      approveCreditClose(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, approve_body} =
      gql(ctx.conn, approve,
        token: outsider.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "creditCloseId" => close["id"],
            "clientMutationId" => "approve-cross"
          }
        }
      )

    refute get_in(approve_body, ["data", "approveCreditClose", "__typename"]) ==
             "ApproveCreditCloseSuccess"
  end
end
