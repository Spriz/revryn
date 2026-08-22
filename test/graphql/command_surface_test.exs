defmodule BillingCoreWeb.GraphQL.CommandSurfaceTest do
  @moduledoc """
  Focused coverage of the remaining command surface: organization/team
  creation, one-time charge instances, billing runs, and intent supersession.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  alias BillingCore.{Billing, Identity}

  test "createOrganization bootstraps the first team; createTeam adds another", %{conn: conn} do
    user = user_fixture()
    {token, _session} = Identity.create_session(user)

    create_organization = """
    mutation CreateOrganization($input: CreateOrganizationInput!) {
      createOrganization(input: $input) {
        __typename
        ... on CreateOrganizationSuccess {
          clientMutationId
          organization { id name slug status }
          team { id name organizationId baseCurrency }
        }
      }
    }
    """

    {200, %{"data" => %{"createOrganization" => created}}} =
      gql(conn, create_organization,
        token: token,
        variables: %{
          "input" => %{"name" => "Nordwind ApS", "clientMutationId" => "cm-org"}
        }
      )

    assert created["__typename"] == "CreateOrganizationSuccess"
    org_id = created["organization"]["id"]
    assert created["team"]["organizationId"] == org_id
    assert created["organization"]["status"] == "active"

    create_team = """
    mutation CreateTeam($input: CreateTeamInput!) {
      createTeam(input: $input) {
        __typename
        ... on CreateTeamSuccess { team { id name organizationId } }
        ... on AuthorizationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"createTeam" => team_payload}}} =
      gql(conn, create_team,
        token: token,
        variables: %{
          "input" => %{
            "organizationId" => org_id,
            "name" => "Denmark",
            "clientMutationId" => "cm-team"
          }
        }
      )

    assert team_payload["__typename"] == "CreateTeamSuccess"
    assert team_payload["team"]["organizationId"] == org_id

    # An unrelated user cannot create teams in this organization.
    outsider = user_fixture()
    {outsider_token, _} = Identity.create_session(outsider)

    {200, %{"data" => %{"createTeam" => denied}}} =
      gql(conn, create_team,
        token: outsider_token,
        variables: %{
          "input" => %{
            "organizationId" => org_id,
            "name" => "Sweden",
            "clientMutationId" => "cm-denied"
          }
        }
      )

    assert denied["__typename"] == "AuthorizationProblem"
  end

  test "createChargeInstance is idempotent by key and replayable", %{conn: conn} do
    ctx = register_actor()
    contract = contract_fixture(ctx.scope)

    mutation = """
    mutation CreateChargeInstance($input: CreateChargeInstanceInput!) {
      createChargeInstance(input: $input) {
        __typename
        ... on CreateChargeInstanceSuccess {
          chargeInstance { id externalId status amountMinor currency recognitionMode }
        }
        ... on ValidationProblem { code }
        ... on IdempotencyConflict { code }
      }
    }
    """

    input = %{
      "teamId" => ctx.team.id,
      "contractId" => contract.id,
      "externalId" => "chg-gql-1",
      "productId" => Ecto.UUID.generate(),
      "productVersion" => 1,
      "eligibleOn" => Date.to_iso8601(Date.utc_today()),
      "recognitionMode" => "POINT_IN_TIME",
      "amountMinor" => 25_000,
      "idempotencyKey" => "charge-key-1",
      "clientMutationId" => "cm-charge"
    }

    {200, %{"data" => %{"createChargeInstance" => created}}} =
      gql(conn, mutation, token: ctx.token, variables: %{"input" => input})

    assert created["__typename"] == "CreateChargeInstanceSuccess"
    charge = created["chargeInstance"]
    assert charge["status"] == "pending"
    assert charge["amountMinor"] == 25_000
    assert charge["currency"] == "DKK"

    {200, %{"data" => %{"createChargeInstance" => replay}}} =
      gql(conn, mutation, token: ctx.token, variables: %{"input" => input})

    assert replay["chargeInstance"]["id"] == charge["id"]

    different = Map.put(input, "amountMinor", 99_000)

    {200, %{"data" => %{"createChargeInstance" => conflict}}} =
      gql(conn, mutation, token: ctx.token, variables: %{"input" => different})

    assert conflict["__typename"] == "IdempotencyConflict"
  end

  test "createBillingRun opens a run queryable via billingRun", %{conn: conn} do
    ctx = register_actor()

    mutation = """
    mutation CreateBillingRun($input: CreateBillingRunInput!) {
      createBillingRun(input: $input) {
        __typename
        ... on CreateBillingRunSuccess {
          billingRun { id runKey status invoiceDate engineVersion }
        }
      }
    }
    """

    input = %{
      "teamId" => ctx.team.id,
      "runKey" => "2026-09-standard",
      "invoiceDate" => "2026-09-01",
      "usageCutoff" => "2026-09-01T00:00:00Z",
      "idempotencyKey" => "run-key-1",
      "clientMutationId" => "cm-run"
    }

    {200, %{"data" => %{"createBillingRun" => created}}} =
      gql(conn, mutation, token: ctx.token, variables: %{"input" => input})

    assert created["__typename"] == "CreateBillingRunSuccess"
    run = created["billingRun"]
    assert run["runKey"] == "2026-09-standard"
    assert run["status"] == "open"

    {200, %{"data" => %{"createBillingRun" => replayed}}} =
      gql(conn, mutation, token: ctx.token, variables: %{"input" => input})

    assert replayed["billingRun"]["id"] == run["id"]

    query = """
    query BillingRun($teamId: ID!, $id: ID!) {
      billingRun(teamId: $teamId, id: $id) { id status invoiceDate }
    }
    """

    {200, %{"data" => %{"billingRun" => fetched}}} =
      gql(conn, query, token: ctx.token, variables: %{"teamId" => ctx.team.id, "id" => run["id"]})

    assert fetched["status"] == "open"
    assert fetched["invoiceDate"] == "2026-09-01"
  end

  test "supersedeInvoiceIntent replaces a frozen intent in the same chain", %{conn: conn} do
    ctx = register_actor()
    plan_version = published_plan_version_fixture(ctx.scope, amount: "100")
    contract = contract_fixture(ctx.scope)

    subscription =
      subscription_fixture(ctx.scope,
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        quantity: Decimal.new(1),
        start_date: Date.utc_today()
      )

    today = Date.to_iso8601(Date.utc_today())

    freeze = """
    mutation Freeze($input: FreezeInvoiceIntentInput!) {
      freezeInvoiceIntent(input: $input) {
        ... on FreezeInvoiceIntentSuccess {
          invoiceIntent { id state intentVersion netAmountMinor }
        }
      }
    }
    """

    {200, %{"data" => %{"freezeInvoiceIntent" => %{"invoiceIntent" => original}}}} =
      gql(conn, freeze,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => subscription.id,
            "asOf" => today,
            "idempotencyKey" => "freeze-super",
            "clientMutationId" => "cm"
          }
        }
      )

    assert original["intentVersion"] == 1

    supersede = """
    mutation Supersede($input: SupersedeInvoiceIntentInput!) {
      supersedeInvoiceIntent(input: $input) {
        __typename
        ... on SupersedeInvoiceIntentSuccess {
          invoiceIntent {
            id state intentVersion supersedesInvoiceIntentId
            lines { lineKey ordinal amountMinor }
          }
        }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"supersedeInvoiceIntent" => payload}}} =
      gql(conn, supersede,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => original["id"],
            "subscriptionId" => subscription.id,
            "asOf" => today,
            "reason" => "customer data corrected",
            "clientMutationId" => "cm-supersede"
          }
        }
      )

    assert payload["__typename"] == "SupersedeInvoiceIntentSuccess"
    replacement = payload["invoiceIntent"]
    assert replacement["intentVersion"] == 2
    assert replacement["supersedesInvoiceIntentId"] == original["id"]
    assert replacement["state"] == "frozen"
    assert [%{"amountMinor" => 10_000, "ordinal" => _}] = replacement["lines"]

    # The original intent is now superseded (immutable, kept in the chain).
    {:ok, old_intent} = Billing.get_intent(ctx.scope, original["id"])
    assert Billing.intent_state(old_intent) == "superseded"

    # Superseding the already-superseded intent again is an illegal
    # transition, not a crash (booked/superseded documents are immutable).
    {200, %{"data" => %{"supersedeInvoiceIntent" => again}}} =
      gql(conn, supersede,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => original["id"],
            "subscriptionId" => subscription.id,
            "asOf" => today,
            "clientMutationId" => "cm-again"
          }
        }
      )

    assert again["__typename"] == "ValidationProblem"
    assert again["code"] == "ILLEGAL_STATE"

    # An unknown intent and an unknown preview subscription each map to
    # their own typed problem before any write.
    {200, %{"data" => %{"supersedeInvoiceIntent" => missing_intent}}} =
      gql(conn, supersede,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => Ecto.UUID.generate(),
            "subscriptionId" => subscription.id,
            "asOf" => today,
            "clientMutationId" => "cm-missing-intent"
          }
        }
      )

    assert missing_intent["code"] == "NOT_FOUND"

    {200, %{"data" => %{"supersedeInvoiceIntent" => missing_subscription}}} =
      gql(conn, supersede,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => replacement["id"],
            "subscriptionId" => Ecto.UUID.generate(),
            "asOf" => today,
            "clientMutationId" => "cm-missing-sub"
          }
        }
      )

    assert missing_subscription["code"] == "NOT_FOUND"
  end

  # Not covered on purpose in the Billing/Contracts resolvers:
  #   * the read-denied (`can_read?`/`:unauthorized`) branches — a resolved
  #     team scope always holds at least one role, and every canonical team
  #     role grants read access;
  #   * the supersede `{:blockers, ...}` branch — preview blockers require a
  #     rating/aggregation failure that published-plan validation prevents;
  #   * `resolve_outcome`'s fetch-failed and missing-resource_reference
  #     branches and `fetch_billing_run`'s nil branch — an executed/replayed
  #     idempotency record always references a fetchable team resource.

  test "contract and subscription resolve by ID; unknown IDs are NOT_FOUND", %{conn: conn} do
    ctx = register_actor()
    plan_version = published_plan_version_fixture(ctx.scope)
    contract = contract_fixture(ctx.scope)

    subscription =
      subscription_fixture(ctx.scope,
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.utc_today()
      )

    query = """
    query Records($teamId: ID!, $contractId: ID!, $subscriptionId: ID!) {
      contract(teamId: $teamId, id: $contractId) { id currency status }
      subscription(teamId: $teamId, id: $subscriptionId) { id externalId state }
    }
    """

    {200, %{"data" => data}} =
      gql(conn, query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "contractId" => contract.id,
          "subscriptionId" => subscription.id
        }
      )

    assert data["contract"]["id"] == contract.id
    assert data["subscription"]["externalId"] == subscription.external_id

    {200, missing} =
      gql(conn, query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "contractId" => Ecto.UUID.generate(),
          "subscriptionId" => Ecto.UUID.generate()
        }
      )

    assert missing["data"]["contract"] == nil
    assert missing["data"]["subscription"] == nil
    assert Enum.all?(missing["errors"], &(&1["code"] == "NOT_FOUND"))
  end

  test "subscriptions connection enforces page size and cursor validity", %{conn: conn} do
    ctx = register_actor()

    query = """
    query Subscriptions($teamId: ID!, $first: Int, $after: String) {
      subscriptions(teamId: $teamId, first: $first, after: $after) {
        edges { node { id } }
      }
    }
    """

    {200, oversized} =
      gql(conn, query, token: ctx.token, variables: %{"teamId" => ctx.team.id, "first" => 101})

    assert [%{"code" => "INVALID_PAGE_SIZE"} | _] = oversized["errors"]

    {200, garbled} =
      gql(conn, query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "first" => 5, "after" => "garbled"}
      )

    assert [%{"code" => "INVALID_CURSOR"} | _] = garbled["errors"]
  end

  test "createContract succeeds and rejects an unknown customer with a typed problem", %{
    conn: conn
  } do
    ctx = register_actor()
    customer = customer_fixture(ctx.scope)

    mutation = """
    mutation CreateContract($input: CreateContractInput!) {
      createContract(input: $input) {
        __typename
        ... on CreateContractSuccess {
          clientMutationId
          contract { id customerId currency startDate status }
        }
        ... on ValidationProblem { code }
      }
    }
    """

    input = %{
      "teamId" => ctx.team.id,
      "customerId" => customer.id,
      "currency" => "DKK",
      "startDate" => "2026-01-01",
      "externalReference" => "ref-#{System.unique_integer([:positive])}",
      "clientMutationId" => "cm-contract"
    }

    {200, %{"data" => %{"createContract" => created}}} =
      gql(conn, mutation, token: ctx.token, variables: %{"input" => input})

    assert created["__typename"] == "CreateContractSuccess"
    assert created["contract"]["customerId"] == customer.id
    assert created["contract"]["currency"] == "DKK"

    {200, %{"data" => %{"createContract" => rejected}}} =
      gql(conn, mutation,
        token: ctx.token,
        variables: %{"input" => Map.put(input, "customerId", Ecto.UUID.generate())}
      )

    assert rejected["__typename"] == "ValidationProblem"
    assert rejected["code"] == "CUSTOMER_NOT_FOUND"
  end

  test "createChargeInstance with an unknown contract is a typed problem", %{conn: conn} do
    ctx = register_actor()

    mutation = """
    mutation CreateChargeInstance($input: CreateChargeInstanceInput!) {
      createChargeInstance(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"createChargeInstance" => payload}}} =
      gql(conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "contractId" => Ecto.UUID.generate(),
            "externalId" => "chg-orphan",
            "productId" => Ecto.UUID.generate(),
            "productVersion" => 1,
            "eligibleOn" => Date.to_iso8601(Date.utc_today()),
            "recognitionMode" => "POINT_IN_TIME",
            "amountMinor" => 1_000,
            "idempotencyKey" => "charge-orphan",
            "clientMutationId" => "cm"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "CONTRACT_NOT_FOUND"
  end

  test "an auditor may read but not open billing runs", %{conn: conn} do
    ctx = register_actor([:auditor])

    mutation = """
    mutation CreateBillingRun($input: CreateBillingRunInput!) {
      createBillingRun(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"createBillingRun" => payload}}} =
      gql(conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "runKey" => "2026-10-standard",
            "invoiceDate" => "2026-10-01",
            "usageCutoff" => "2026-10-01T00:00:00Z",
            "idempotencyKey" => "run-auditor",
            "clientMutationId" => "cm-denied"
          }
        }
      )

    assert payload["__typename"] == "AuthorizationProblem"
    assert payload["code"] == "UNAUTHORIZED"
  end

  test "billingRun and invoiceIntent lookups with unknown IDs are NOT_FOUND", %{conn: conn} do
    ctx = register_actor()

    query = """
    query Lookups($teamId: ID!, $runId: ID!, $intentId: ID!) {
      billingRun(teamId: $teamId, id: $runId) { id }
      invoiceIntent(teamId: $teamId, id: $intentId) { id }
    }
    """

    {200, body} =
      gql(conn, query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "runId" => Ecto.UUID.generate(),
          "intentId" => Ecto.UUID.generate()
        }
      )

    assert body["data"]["billingRun"] == nil
    assert body["data"]["invoiceIntent"] == nil
    assert Enum.all?(body["errors"], &(&1["code"] == "NOT_FOUND"))
  end

  test "invoicePreview distinguishes unknown subscriptions from uneffective dates", %{conn: conn} do
    ctx = register_actor()
    plan_version = published_plan_version_fixture(ctx.scope)
    contract = contract_fixture(ctx.scope)

    subscription =
      subscription_fixture(ctx.scope,
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.utc_today()
      )

    query = """
    query Preview($teamId: ID!, $subscriptionId: ID!, $asOf: Date!) {
      invoicePreview(teamId: $teamId, subscriptionId: $subscriptionId, asOf: $asOf) {
        netAmountMinor
      }
    }
    """

    {200, missing} =
      gql(conn, query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "subscriptionId" => Ecto.UUID.generate(),
          "asOf" => Date.to_iso8601(Date.utc_today())
        }
      )

    assert [%{"code" => "NOT_FOUND"} | _] = missing["errors"]

    # A date before any effective subscription version has a distinct,
    # stable code instead of a generic failure.
    {200, early} =
      gql(conn, query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "subscriptionId" => subscription.id,
          "asOf" => Date.to_iso8601(Date.add(Date.utc_today(), -30))
        }
      )

    assert [%{"code" => "NO_EFFECTIVE_SUBSCRIPTION_VERSION"} | _] = early["errors"]
  end

  test "freezeInvoiceIntent with an unknown subscription is a typed problem", %{conn: conn} do
    ctx = register_actor()

    freeze = """
    mutation Freeze($input: FreezeInvoiceIntentInput!) {
      freezeInvoiceIntent(input: $input) {
        __typename
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"freezeInvoiceIntent" => payload}}} =
      gql(conn, freeze,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => Ecto.UUID.generate(),
            "asOf" => Date.to_iso8601(Date.utc_today()),
            "idempotencyKey" => "freeze-missing",
            "clientMutationId" => "cm"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "NOT_FOUND"
  end

  test "createOrganization rejects unauthenticated callers and invalid input", %{conn: conn} do
    mutation = """
    mutation CreateOrganization($input: CreateOrganizationInput!) {
      createOrganization(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
        ... on ValidationProblem { code fields { path } }
      }
    }
    """

    # No bearer token at all: the resolver refuses before touching Orgs.
    {200, %{"data" => %{"createOrganization" => anonymous}}} =
      gql(conn, mutation,
        variables: %{"input" => %{"name" => "Ghost ApS", "clientMutationId" => "cm-anon"}}
      )

    assert anonymous["__typename"] == "AuthorizationProblem"

    # Authenticated but invalid attributes surface the changeset problem.
    user = user_fixture()
    {token, _session} = Identity.create_session(user)

    {200, %{"data" => %{"createOrganization" => invalid}}} =
      gql(conn, mutation,
        token: token,
        variables: %{"input" => %{"name" => "", "clientMutationId" => "cm-blank"}}
      )

    assert invalid["__typename"] == "ValidationProblem"
    assert invalid["code"] == "VALIDATION_FAILED"
  end

  test "createTeam requires an organization admin and valid attributes", %{conn: conn} do
    ctx = register_actor()

    # A plain organization member resolves scope but lacks the admin role.
    member = user_fixture()
    organization_membership_fixture(ctx.organization, member, [:organization_member])
    {member_token, _session} = Identity.create_session(member)

    mutation = """
    mutation CreateTeam($input: CreateTeamInput!) {
      createTeam(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"createTeam" => denied}}} =
      gql(conn, mutation,
        token: member_token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "name" => "Skunkworks",
            "clientMutationId" => "cm-member"
          }
        }
      )

    assert denied["__typename"] == "AuthorizationProblem"
    assert denied["code"] == "UNAUTHORIZED"

    # The owner with a blank name gets the changeset problem.
    {200, %{"data" => %{"createTeam" => invalid}}} =
      gql(conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "name" => "",
            "clientMutationId" => "cm-blank"
          }
        }
      )

    assert invalid["__typename"] == "ValidationProblem"
    assert invalid["code"] == "VALIDATION_FAILED"
  end
end
