defmodule BillingCoreWeb.GraphQL.BillingErpWorkflowTest do
  @moduledoc """
  End-to-end over the public API: preview → freeze → synchronize → operation
  follow-up → approve → book (SPEC §1.2 vertical slice, §14.11), with the
  stateful fake ERP at the network boundary.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  alias BillingCore.{Catalog, Contracts, ERP}
  alias BillingCore.ERP.FakeERP

  setup %{conn: conn} do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    ctx = register_actor([:team_admin, :billing_admin, :finance_operator])

    {:ok, connection} =
      ERP.create_connection(ctx.scope, %{provider: "fake", secret_reference: "unused"})

    customer = customer_fixture(ctx.scope)

    {:ok, _mapping} =
      Contracts.upsert_customer_erp_mapping(ctx.scope, customer, %{
        erp_connection_id: connection.id,
        external_customer_number: "1001"
      })

    product = product_fixture(ctx.scope)

    {:ok, _mapping} =
      Catalog.upsert_product_erp_mapping(ctx.scope, product, %{
        erp_connection_id: connection.id,
        external_product_number: "SAAS-BASE"
      })

    plan_version = published_plan_version_fixture(ctx.scope, product: product, amount: "100")
    contract = contract_fixture(ctx.scope, customer_id: customer.id)

    subscription =
      subscription_fixture(ctx.scope,
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        quantity: Decimal.new(1),
        start_date: Date.utc_today()
      )

    Map.merge(ctx, %{
      conn: conn,
      fake: fake,
      connection: connection,
      customer: customer,
      subscription: subscription
    })
  end

  defp drain_erp_queue do
    Oban.drain_queue(queue: :erp, with_safety: false)
  end

  test "validateErpConnection activates the connection", ctx do
    mutation = """
    mutation ValidateErpConnection($input: ValidateErpConnectionInput!) {
      validateErpConnection(input: $input) {
        __typename
        ... on ValidateErpConnectionSuccess {
          erpConnection { id provider status lastValidatedAt }
        }
      }
    }
    """

    {200, %{"data" => %{"validateErpConnection" => payload}}} =
      gql(ctx.conn, mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "erpConnectionId" => ctx.connection.id,
            "clientMutationId" => "cm-validate"
          }
        }
      )

    assert payload["__typename"] == "ValidateErpConnectionSuccess"
    assert payload["erpConnection"]["status"] == "active"
  end

  test "preview → freeze → synchronize → operation succeeds → intent erp_draft → approve → book",
       ctx do
    {:ok, _} = ERP.validate_connection(ctx.scope, ctx.connection)
    today = Date.to_iso8601(Date.utc_today())

    # 1. Deterministic preview with no blockers.
    preview_query = """
    query Preview($teamId: ID!, $subscriptionId: ID!, $asOf: Date!) {
      invoicePreview(teamId: $teamId, subscriptionId: $subscriptionId, asOf: $asOf) {
        netAmountMinor
        fingerprint
        blockers
        lines { lineKey amountMinor quantity recognitionMode }
      }
    }
    """

    {200, %{"data" => %{"invoicePreview" => preview}}} =
      gql(ctx.conn, preview_query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "subscriptionId" => ctx.subscription.id,
          "asOf" => today
        }
      )

    assert preview["blockers"] == []
    assert preview["netAmountMinor"] == 10_000
    assert is_binary(preview["fingerprint"])
    assert [%{"amountMinor" => 10_000, "quantity" => "1"}] = preview["lines"]

    # 2. Freeze the preview into immutable invoice intent.
    freeze = """
    mutation Freeze($input: FreezeInvoiceIntentInput!) {
      freezeInvoiceIntent(input: $input) {
        __typename
        ... on FreezeInvoiceIntentSuccess {
          invoiceIntent {
            id state netAmountMinor contentHash intentVersion
            lines { lineKey amountMinor ordinal }
          }
        }
        ... on MappingProblem { code fields { code message } }
        ... on ValidationProblem { code }
      }
    }
    """

    freeze_input = %{
      "teamId" => ctx.team.id,
      "subscriptionId" => ctx.subscription.id,
      "asOf" => today,
      "idempotencyKey" => "freeze-1",
      "clientMutationId" => "cm-freeze"
    }

    {200, %{"data" => %{"freezeInvoiceIntent" => frozen}}} =
      gql(ctx.conn, freeze, token: ctx.token, variables: %{"input" => freeze_input})

    assert frozen["__typename"] == "FreezeInvoiceIntentSuccess"
    intent = frozen["invoiceIntent"]
    assert intent["state"] == "frozen"
    assert intent["netAmountMinor"] == 10_000
    assert [%{"amountMinor" => 10_000}] = intent["lines"]

    # Idempotent replay returns the same intent.
    {200, %{"data" => %{"freezeInvoiceIntent" => refrozen}}} =
      gql(ctx.conn, freeze, token: ctx.token, variables: %{"input" => freeze_input})

    assert refrozen["invoiceIntent"]["id"] == intent["id"]

    # 3. Synchronize returns the durable operation to follow (SPEC §14.11).
    synchronize = """
    mutation Synchronize($input: SynchronizeInvoiceInput!) {
      synchronizeInvoice(input: $input) {
        __typename
        ... on SynchronizeInvoiceAccepted {
          clientMutationId
          operation { id state type }
        }
        ... on MappingProblem { code fields { code message } }
      }
    }
    """

    sync_input = %{
      "teamId" => ctx.team.id,
      "invoiceIntentId" => intent["id"],
      "idempotencyKey" => "sync-1",
      "clientMutationId" => "cm-sync"
    }

    {200, %{"data" => %{"synchronizeInvoice" => accepted}}} =
      gql(ctx.conn, synchronize, token: ctx.token, variables: %{"input" => sync_input})

    assert accepted["__typename"] == "SynchronizeInvoiceAccepted"
    assert accepted["operation"]["state"] == "queued"
    assert accepted["operation"]["type"] == "erp.create_draft"
    operation_id = accepted["operation"]["id"]

    # Replay returns the same operation instead of enqueueing again.
    {200, %{"data" => %{"synchronizeInvoice" => replay}}} =
      gql(ctx.conn, synchronize, token: ctx.token, variables: %{"input" => sync_input})

    assert replay["operation"]["id"] == operation_id

    # 4. The worker runs; the operation and intent report the outcome.
    assert %{success: 1} = drain_erp_queue()

    follow_up = """
    query FollowUp($teamId: ID!, $operationId: ID!, $intentId: ID!) {
      operation(teamId: $teamId, id: $operationId) { id state }
      invoiceIntent(teamId: $teamId, id: $intentId) { id state }
    }
    """

    {200, %{"data" => followed}} =
      gql(ctx.conn, follow_up,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "operationId" => operation_id,
          "intentId" => intent["id"]
        }
      )

    assert followed["operation"]["state"] == "succeeded"
    assert followed["invoiceIntent"]["state"] == "erp_draft"

    # 5. Approve, then book through the durable booking operation.
    approve = """
    mutation Approve($input: ApproveInvoiceInput!) {
      approveInvoice(input: $input) {
        __typename
        ... on ApproveInvoiceSuccess { invoiceIntent { id state } }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"approveInvoice" => approved}}} =
      gql(ctx.conn, approve,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => intent["id"],
            "reason" => "reviewed",
            "clientMutationId" => "cm-approve"
          }
        }
      )

    assert approved["__typename"] == "ApproveInvoiceSuccess"
    assert approved["invoiceIntent"]["state"] == "approved"

    book = """
    mutation Book($input: BookInvoiceInput!) {
      bookInvoice(input: $input) {
        __typename
        ... on BookInvoiceAccepted { operation { id state type } }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"bookInvoice" => booking}}} =
      gql(ctx.conn, book,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => intent["id"],
            "idempotencyKey" => "book-1",
            "clientMutationId" => "cm-book"
          }
        }
      )

    assert booking["__typename"] == "BookInvoiceAccepted"
    assert booking["operation"]["type"] == "erp.book_document"

    assert %{success: 1} = drain_erp_queue()

    {200, %{"data" => booked}} =
      gql(ctx.conn, follow_up,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "operationId" => booking["operation"]["id"],
          "intentId" => intent["id"]
        }
      )

    assert booked["operation"]["state"] == "succeeded"
    assert booked["invoiceIntent"]["state"] == "erp_booked"
  end

  test "synchronizing without a product mapping is a typed MappingProblem", ctx do
    {:ok, _} = ERP.validate_connection(ctx.scope, ctx.connection)

    # A second product without an ERP mapping in a fresh plan/subscription.
    orphan_product = product_fixture(ctx.scope)
    plan_version = published_plan_version_fixture(ctx.scope, product: orphan_product)
    contract = contract_fixture(ctx.scope, customer_id: ctx.customer.id)

    subscription =
      subscription_fixture(ctx.scope,
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.utc_today()
      )

    today = Date.to_iso8601(Date.utc_today())

    freeze = """
    mutation Freeze($input: FreezeInvoiceIntentInput!) {
      freezeInvoiceIntent(input: $input) {
        ... on FreezeInvoiceIntentSuccess { invoiceIntent { id } }
      }
    }
    """

    {200, %{"data" => %{"freezeInvoiceIntent" => %{"invoiceIntent" => %{"id" => intent_id}}}}} =
      gql(ctx.conn, freeze,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "subscriptionId" => subscription.id,
            "asOf" => today,
            "idempotencyKey" => "freeze-orphan",
            "clientMutationId" => "cm"
          }
        }
      )

    synchronize = """
    mutation Synchronize($input: SynchronizeInvoiceInput!) {
      synchronizeInvoice(input: $input) {
        __typename
        ... on MappingProblem { code fields { code message } }
      }
    }
    """

    {200, %{"data" => %{"synchronizeInvoice" => payload}}} =
      gql(ctx.conn, synchronize,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "invoiceIntentId" => intent_id,
            "idempotencyKey" => "sync-orphan",
            "clientMutationId" => "cm"
          }
        }
      )

    assert payload["__typename"] == "MappingProblem"
    assert payload["code"] == "BLOCKED"
    assert Enum.any?(payload["fields"], &(&1["code"] == "PRODUCT_MAPPING_MISSING"))
  end

  test "retryOperation requires the finance role", ctx do
    limited = register_actor([:billing_admin])

    # Membership in a different team entirely: AuthorizationProblem from scope.
    mutation = """
    mutation Retry($input: RetryOperationInput!) {
      retryOperation(input: $input) {
        __typename
        ... on AuthorizationProblem { code }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"retryOperation" => payload}}} =
      gql(ctx.conn, mutation,
        token: limited.token,
        variables: %{
          "input" => %{
            "teamId" => limited.team.id,
            "operationId" => Ecto.UUID.generate(),
            "clientMutationId" => "cm-retry"
          }
        }
      )

    assert payload["__typename"] == "AuthorizationProblem"
    assert payload["code"] == "UNAUTHORIZED"
  end
end
