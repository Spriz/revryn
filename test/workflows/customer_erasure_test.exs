defmodule BillingCore.Workflows.CustomerErasureTest do
  @moduledoc """
  SPEC §20 customer erasure: pseudonymize operational personal data
  forward through the ordinary append-only version history, retain the
  financial evidence that invoices and closes depend on, refuse while
  contractual retention (live subscriptions) applies, and audit the act.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.CatalogFixtures
  import BillingCore.ContractsFixtures

  alias BillingCore.{Audit, Contracts, Privacy}
  alias BillingCore.Contracts.CustomerVersion

  setup do
    scope = billing_scope_fixture([:team_admin, :billing_admin, :finance_operator])

    {:ok, %{customer: customer}} =
      Contracts.upsert_customer(scope, %{
        external_id: "erasure-#{System.unique_integer([:positive])}",
        legal_name: "Fjordlys Konsulenterne ApS",
        email: "kontakt@fjordlys.example",
        address_line: "Havnegade 12",
        zip: "9000",
        city: "Aalborg",
        country: "DK",
        vat_number: "DK12345678"
      })

    %{scope: scope, customer: customer}
  end

  test "erasure appends a pseudonymized version and retains history", %{
    scope: scope,
    customer: customer
  } do
    assert {:ok, %{customer: erased, retained: retained}} =
             Privacy.erase_customer(scope, customer.id, "GDPR deletion request #4711")

    assert :frozen_invoice_evidence in retained

    # Forward-facing data is pseudonymized in a NEW immutable version.
    assert erased.current_version == customer.current_version + 1

    current =
      Repo.get_by!(CustomerVersion, customer_id: customer.id, version: erased.current_version)

    assert current.legal_name =~ "Erased customer"
    assert current.email =~ "@anonymized.invalid"
    assert is_nil(current.vat_number)
    assert is_nil(current.address_line)

    # The historical snapshot is retained verbatim — financial evidence
    # under the accountant-approved policy, still append-only.
    original = Repo.get_by!(CustomerVersion, customer_id: customer.id, version: 1)
    assert original.legal_name == "Fjordlys Konsulenterne ApS"

    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.update_all(
        from(v in CustomerVersion, where: v.id == ^original.id),
        set: [legal_name: "redacted"]
      )
    end

    assert Repo.exists?(from a in Audit.Entry, where: a.event_type == "privacy.customer_erased")
  end

  test "erasure is refused while live subscriptions exist, then allowed after cancellation",
       %{scope: scope, customer: customer} do
    plan_version = published_plan_version_fixture(scope, currency: "DKK", interval_count: 1)

    contract =
      contract_fixture(scope, %{
        customer_id: customer.id,
        start_date: Date.add(Date.utc_today(), -30)
      })

    {:ok, subscription} =
      Contracts.start_subscription(scope, %{
        external_id: unique_subscription_external_id(),
        contract_id: contract.id,
        plan_version_id: plan_version.id,
        start_date: Date.add(Date.utc_today(), -30),
        quantity: Decimal.new(1)
      })

    assert {:error, :active_subscriptions} =
             Privacy.erase_customer(scope, customer.id, "deletion request")

    {:ok, _} =
      Contracts.cancel_subscription(scope, subscription, %{
        mode: :immediate,
        reason: "relationship ended"
      })

    assert {:ok, _result} = Privacy.erase_customer(scope, customer.id, "deletion request")
  end

  test "erasure is team-admin gated and requires a reason", %{scope: scope, customer: customer} do
    finance = team_scope_fixture(scope.organization, scope.team, [:finance_operator])

    assert {:error, :unauthorized} =
             Privacy.erase_customer(finance, customer.id, "deletion request")

    assert {:error, :reason_required} = Privacy.erase_customer(scope, customer.id, "  ")
  end
end
