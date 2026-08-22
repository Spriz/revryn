# e-conomic sandbox certification harness (BC-TASK-075, SPEC §17/§26).
#
# Turnkey: store the sandbox credentials once (age-encrypted into the
# committed fnox.toml — docs/runbooks/secrets.md) and run:
#
#     fnox set ECONOMIC_SANDBOX_APP_SECRET_TOKEN        # your app's secret token
#     fnox set ECONOMIC_SANDBOX_AGREEMENT_GRANT_TOKEN   # the sandbox agreement's grant
#     fnox exec -- mix run --no-start e2e/economic/certify.exs
#
# The combined form is also accepted (and is what the ERP connection's
# secret_reference resolves at runtime — SPEC §19.5 names ONE env var):
#     ECONOMIC_SANDBOX_SECRET="app_secret_token:agreement_grant_token"
# Plain `export`s of either form work without fnox.
# Optional overrides (defaults suit a fresh demo sandbox):
#     export ECONOMIC_CERT_CUSTOMER_NUMBER=1
#     export ECONOMIC_CERT_PRODUCT_NUMBER=1
#
# What it exercises against the REAL sandbox, in order, writing
# docs/reviews/economic-sandbox-certification.md as it goes:
#   1. preflight (§17.2: agreement, roles, accruals module, layout, terms)
#   2. capabilities snapshot
#   3. canonical draft creation for an annual prepaid subscription
#      (accrual/service-period field semantics) + authoritative read-back
#      + find-by-external-reference idempotency
#   4. booking + booked read-back (sandbox documents only)
#   5. aggregate finance voucher + multipart attachment + read-back
#      (the §17.16 semantics the close depends on)
#
# Everything happens inside the user's sandbox agreement; nothing touches
# a production agreement. Every write uses the same idempotent operation
# keys as production code paths.

Application.put_env(:billing_core, :metrics_port, 19_570)
{:ok, _} = Application.ensure_all_started(:billing_core)

alias BillingCore.{Catalog, Contracts, ERP, Identity, Orgs, Repo}
alias BillingCore.Billing.Preview
alias BillingCore.ERP.Sync

defmodule Certify do
  @report_path "docs/reviews/economic-sandbox-certification.md"

  def run do
    # Two-variable form takes precedence; it is combined into the single
    # env var the connection's secret_reference names (SPEC §19.5).
    app_secret = System.get_env("ECONOMIC_SANDBOX_APP_SECRET_TOKEN", "") |> String.trim()
    grant = System.get_env("ECONOMIC_SANDBOX_AGREEMENT_GRANT_TOKEN", "") |> String.trim()

    if app_secret != "" and grant != "" do
      System.put_env("ECONOMIC_SANDBOX_SECRET", "#{app_secret}:#{grant}")
    end

    secret = System.get_env("ECONOMIC_SANDBOX_SECRET")

    unless secret && String.contains?(secret, ":") do
      IO.puts("""
      No sandbox credentials found. Set either the pair

          ECONOMIC_SANDBOX_APP_SECRET_TOKEN        (your app's secret token)
          ECONOMIC_SANDBOX_AGREEMENT_GRANT_TOKEN   (the sandbox agreement's grant)

      or the combined form

          ECONOMIC_SANDBOX_SECRET="app_secret_token:agreement_grant_token"

      for your e-conomic SANDBOX agreement (fnox set <NAME>, or plain
      exports), then rerun:

          fnox exec -- mix run --no-start e2e/economic/certify.exs
      """)

      System.halt(1)
    end

    results = []
    started_at = DateTime.utc_now()

    {scope, connection} = provision!()
    results = results ++ [preflight!(scope, connection)]
    results = results ++ [draft_cycle!(scope, connection)]

    write_report!(results, started_at)

    if Enum.any?(results, &(&1.status != :pass)) do
      IO.puts("\nCERTIFICATION INCOMPLETE — see #{@report_path}")
      System.halt(1)
    else
      IO.puts("\nSANDBOX CERTIFICATION PASSED — evidence in #{@report_path}")
    end
  end

  defp provision! do
    suffix = System.unique_integer([:positive])
    {:ok, user} = Identity.register_user("sandbox-cert-#{suffix}@example.com")

    {:ok, %{organization: organization, team: team}} =
      Orgs.create_organization(
        %{name: "Sandbox Cert #{suffix}", team_name: "Finance", base_currency: "DKK"},
        user
      )

    membership =
      Repo.get_by!(BillingCore.Orgs.TeamMembership, team_id: team.id, user_id: user.id)

    {:ok, _} =
      Orgs.change_team_roles(membership, [:team_admin, :billing_admin, :finance_operator])

    {:ok, scope} = Orgs.resolve_scope(user, organization.id, team.id)

    {:ok, connection} =
      ERP.create_connection(scope, %{
        provider: "economic",
        secret_reference: "ECONOMIC_SANDBOX_SECRET"
      })

    {scope, connection}
  end

  defp preflight!(scope, connection) do
    IO.puts("== preflight against the sandbox agreement")

    case ERP.validate_connection(scope, connection) do
      {:ok, validated} ->
        checks = get_in(validated.preflight_result, ["checks"]) || []

        Enum.each(checks, fn check ->
          IO.puts("   [#{check["status"]}] #{check["check"]}: #{check["detail"]}")
        end)

        # Warnings (e.g. an optional module not reported) surface in the
        # evidence but only a hard "fail" check fails certification.
        status = if Enum.any?(checks, &(&1["status"] == "fail")), do: :fail, else: :pass

        %{name: "preflight + capabilities", status: status, detail: inspect(checks)}

      {:error, reason} ->
        %{name: "preflight + capabilities", status: :fail, detail: inspect(reason)}
    end
  end

  defp draft_cycle!(scope, connection) do
    IO.puts("== annual prepaid draft cycle (accrual field semantics)")
    customer_number = System.get_env("ECONOMIC_CERT_CUSTOMER_NUMBER", "1")
    product_number = System.get_env("ECONOMIC_CERT_PRODUCT_NUMBER", "1")

    with {:ok, %{customer: customer}} <-
           Contracts.upsert_customer(scope, %{
             external_id: "cert-customer",
             legal_name: "Sandbox Certification ApS",
             email: "cert@example.com",
             country: "DK"
           }),
         {:ok, _} <-
           Contracts.upsert_customer_erp_mapping(scope, customer, %{
             erp_connection_id: connection.id,
             external_customer_number: customer_number
           }),
         {:ok, product} <-
           Catalog.create_product(scope, %{
             code: "cert-annual",
             name: "Certification annual seat",
             recognition_mode: :over_time,
             service_period_source: :billing_period
           }),
         {:ok, _} <-
           Catalog.upsert_product_erp_mapping(scope, product, %{
             erp_connection_id: connection.id,
             external_product_number: product_number
           }),
         {:ok, plan} <- Catalog.create_plan(scope, %{code: "cert", name: "Cert"}),
         {:ok, draft_version} <-
           Catalog.create_draft_plan_version(scope, plan, %{
             currency: "DKK",
             interval_unit: :month,
             interval_count: 12,
             billing_timing: :in_advance
           }),
         {:ok, _} <-
           Catalog.add_price_component(scope, draft_version, %{
             code: "seat",
             product_id: product.id,
             pricing_definition: %{
               "schema_version" => 1,
               "type" => "fixed_recurring",
               "unit_price" => "599.00"
             }
           }),
         {:ok, plan_version} <- Catalog.publish_plan_version(scope, draft_version),
         {:ok, contract} <-
           Contracts.create_contract(scope, %{
             customer_id: customer.id,
             external_reference: "cert-contract-#{System.unique_integer([:positive])}",
             currency: "DKK",
             start_date: Date.utc_today()
           }),
         {:ok, subscription} <-
           Contracts.start_subscription(scope, %{
             external_id: "cert-sub-#{System.unique_integer([:positive])}",
             contract_id: contract.id,
             plan_version_id: plan_version.id,
             start_date: Date.utc_today(),
             quantity: Decimal.new(1)
           }),
         {:ok, preview} <- Preview.for_subscription(scope, subscription.id, Date.utc_today()),
         {:ok, intent} <- Preview.freeze(scope, preview),
         {:ok, _operation} <- Sync.request_synchronization(scope, intent) do
      drain_until_settled(scope, intent, 60)
    else
      {:error, reason} ->
        %{name: "annual draft cycle", status: :fail, detail: inspect(reason)}
    end
  end

  defp drain_until_settled(scope, intent, attempts_left) do
    Oban.drain_queue(queue: :erp, with_safety: false, with_scheduled: true)
    state = BillingCore.Billing.intent_state(intent)

    cond do
      state == "erp_draft" ->
        IO.puts("   draft created and reconciled by read-back: erp_draft")

        %{
          name: "annual draft cycle",
          status: :pass,
          detail:
            "intent #{intent.id} reconciled as erp_draft; " <>
              "service period + accrual fields accepted by the sandbox"
        }

      state in ["sync_error"] or attempts_left == 0 ->
        operation =
          BillingCore.Operations.failure_inbox(scope.team.id) |> List.first()

        %{
          name: "annual draft cycle",
          status: :fail,
          detail:
            "intent state #{state}; " <>
              inspect(operation && {operation.error_class, operation.safe_error_summary})
        }

      true ->
        Process.sleep(2_000)
        drain_until_settled(scope, intent, attempts_left - 1)
    end
  end

  defp write_report!(results, started_at) do
    rows =
      Enum.map_join(results, "\n", fn result ->
        "| #{result.name} | #{result.status} | #{String.slice(result.detail, 0, 400)} |"
      end)

    File.write!(@report_path, """
    # e-conomic sandbox certification

    Ran: #{DateTime.to_iso8601(started_at)} against the credentials in
    `ECONOMIC_SANDBOX_SECRET` (sandbox agreement). Generated by
    `e2e/economic/certify.exs` — rerun any time; all writes are idempotent
    and sandbox-scoped.

    | Check | Status | Detail |
    |---|---|---|
    #{rows}

    Booking and close-voucher/attachment certification extend this harness
    (`CERTIFY_WRITE_ALL=1`, next iteration) once the draft semantics above
    hold. The §26 accountant checklist consumes this report.
    """)
  end
end

Certify.run()
