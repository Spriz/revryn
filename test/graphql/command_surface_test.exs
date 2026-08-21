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
          invoiceIntent { id state intentVersion supersedesInvoiceIntentId }
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

    # The original intent is now superseded (immutable, kept in the chain).
    {:ok, old_intent} = Billing.get_intent(ctx.scope, original["id"])
    assert Billing.intent_state(old_intent) == "superseded"
  end
end
