defmodule BillingCoreWeb.GraphQL.AuditExportTest do
  @moduledoc """
  Audit-package export over the public API (BC-US-114): the export
  reconstructs the invoice chain with checksummed evidence files, auditors
  can read it, credentials never appear, and cross-team access is denied.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  alias BillingCore.{Catalog, Contracts, ERP}
  alias BillingCore.Billing.Preview
  alias BillingCore.ERP.FakeERP
  alias BillingCore.ERP.Sync

  setup %{conn: conn} do
    fake = start_supervised!({FakeERP, []})
    Application.put_env(:billing_core, :fake_erp_context, %{fake_server: fake})
    on_exit(fn -> Application.delete_env(:billing_core, :fake_erp_context) end)

    ctx = register_actor([:team_admin, :billing_admin, :finance_operator])

    {:ok, connection} =
      ERP.create_connection(ctx.scope, %{provider: "fake", secret_reference: "super-secret-ref"})

    {:ok, _connection} = ERP.validate_connection(ctx.scope, connection)

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
        external_product_number: "SAAS-EXPORT"
      })

    plan_version = published_plan_version_fixture(ctx.scope, product: product, amount: "500")
    contract = contract_fixture(ctx.scope, customer_id: customer.id)

    subscription =
      subscription_fixture(ctx.scope,
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        quantity: Decimal.new(1),
        start_date: Date.utc_today()
      )

    # Freeze → sync → approve → book so the export carries the whole story.
    {:ok, preview} = Preview.for_subscription(ctx.scope, subscription.id, Date.utc_today())
    {:ok, intent} = Preview.freeze(ctx.scope, preview)
    {:ok, _operation} = Sync.request_synchronization(ctx.scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)
    {:ok, _approval} = Sync.approve_invoice(ctx.scope, intent, reason: "export review")
    {:ok, _operation} = Sync.request_booking(ctx.scope, intent)
    assert %{success: 1} = Oban.drain_queue(queue: :erp, with_safety: false)

    Map.merge(ctx, %{conn: conn, intent: intent})
  end

  @query """
  query Export($teamId: ID!, $invoiceIntentId: ID!) {
    auditExport(teamId: $teamId, invoiceIntentId: $invoiceIntentId) {
      invoiceChainId intentCount generatedAt manifestJson
      files { name contentType sha256 contentBase64 }
    }
  }
  """

  test "exports the reconstructed chain with matching checksums", ctx do
    {200, %{"data" => %{"auditExport" => export}}} =
      gql(ctx.conn, @query,
        token: ctx.token,
        variables: %{"teamId" => ctx.team.id, "invoiceIntentId" => ctx.intent.id}
      )

    assert export["intentCount"] == 1
    assert export["invoiceChainId"] == ctx.intent.invoice_chain_id

    files = Map.new(export["files"], fn file -> {file["name"], file} end)

    assert Map.keys(files) |> Enum.sort() ==
             ["audit_log.json", "erp_documents.json", "invoice_chain.json"]

    # Checksums in the manifest match the decoded bytes exactly.
    manifest = Jason.decode!(export["manifestJson"])

    for {name, file} <- files do
      bytes = Base.decode64!(file["contentBase64"])
      recomputed = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      assert recomputed == file["sha256"]
      assert manifest["files"][name]["sha256"] == file["sha256"]
    end

    # The chain document reconstructs the immutable intent with its trace.
    chain = files["invoice_chain.json"]["contentBase64"] |> Base.decode64!() |> Jason.decode!()
    assert [intent_doc] = chain["intents"]
    assert intent_doc["content_hash"] == ctx.intent.content_hash
    assert [line] = intent_doc["lines"]
    assert is_map(line["calculation_trace"])

    assert Enum.any?(chain["state_transitions"], &(&1["to_state"] == "erp_booked"))

    # The ERP evidence carries operation keys and the booked read-back.
    erp = files["erp_documents.json"]["contentBase64"] |> Base.decode64!() |> Jason.decode!()
    assert [doc] = erp["documents"]
    assert doc["external_booked_number"]
    assert Enum.count(erp["sync_operations"]) == 2
    assert [approval] = erp["approvals"]
    assert approval["reason"] == "export review"

    # Credentials never appear anywhere in the export.
    all_bytes =
      files
      |> Map.values()
      |> Enum.map_join("\n", &Base.decode64!(&1["contentBase64"]))

    refute all_bytes =~ "super-secret-ref"
    refute export["manifestJson"] =~ "super-secret-ref"
  end

  test "an auditor can export; an outsider cannot", ctx do
    auditor_user = BillingCore.IdentityFixtures.user_fixture()

    BillingCore.OrgsFixtures.organization_membership_fixture(
      ctx.organization,
      auditor_user,
      [:organization_member]
    )

    BillingCore.OrgsFixtures.team_membership_fixture(ctx.team, auditor_user, [:auditor])
    {auditor_token, _session} = BillingCore.Identity.create_session(auditor_user)

    {200, %{"data" => %{"auditExport" => export}}} =
      gql(ctx.conn, @query,
        token: auditor_token,
        variables: %{"teamId" => ctx.team.id, "invoiceIntentId" => ctx.intent.id}
      )

    assert export["intentCount"] == 1

    outsider = register_actor([:team_admin, :billing_admin, :finance_operator])

    {200, body} =
      gql(ctx.conn, @query,
        token: outsider.token,
        variables: %{"teamId" => ctx.team.id, "invoiceIntentId" => ctx.intent.id}
      )

    assert body["data"]["auditExport"] == nil
    assert [%{"code" => "UNAUTHORIZED"} | _rest] = body["errors"]
  end
end
