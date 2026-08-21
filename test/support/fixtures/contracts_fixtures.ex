defmodule BillingCore.ContractsFixtures do
  @moduledoc """
  Test fixtures for the `BillingCore.Contracts` context.
  """

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias BillingCore.{Contracts, Orgs}

  @doc "A unique customer external ID."
  def unique_customer_external_id, do: "cust-#{System.unique_integer([:positive])}"

  @doc "A unique contract external reference."
  def unique_contract_reference, do: "ctr-#{System.unique_integer([:positive])}"

  @doc "A unique subscription external ID."
  def unique_subscription_external_id, do: "sub-#{System.unique_integer([:positive])}"

  @doc "A unique charge external ID."
  def unique_charge_external_id, do: "chg-#{System.unique_integer([:positive])}"

  @doc """
  A team-resolved scope in a fresh organization whose user holds `roles`
  (default `[:billing_admin]`).
  """
  def billing_scope_fixture(roles \\ [:billing_admin]) do
    %{organization: organization, team: team} = organization_fixture()
    team_scope_fixture(organization, team, roles)
  end

  @doc "A team-resolved scope for a new user with `roles` in an existing team."
  def team_scope_fixture(organization, team, roles) do
    user = user_fixture()
    organization_membership_fixture(organization, user, [:organization_member])
    team_membership_fixture(team, user, roles)
    {:ok, scope} = Orgs.resolve_scope(user, organization.id, team.id)
    scope
  end

  @doc "Complete customer attrs; override any key."
  def valid_customer_attrs(attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put_new(:external_id, unique_customer_external_id())
    |> Map.put_new(:legal_name, "Acme ApS")
    |> Map.put_new(:address_line, "Main Street 1")
    |> Map.put_new(:zip, "8000")
    |> Map.put_new(:city, "Aarhus")
    |> Map.put_new(:country, "DK")
    |> Map.put_new(:email, "billing@example.com")
    |> Map.put_new(:vat_number, "DK12345678")
    |> Map.put_new(:currency_preference, "DKK")
  end

  @doc "Creates a customer via `Contracts.upsert_customer/2`."
  def customer_fixture(scope, attrs \\ %{}) do
    {:ok, %{customer: customer}} = Contracts.upsert_customer(scope, valid_customer_attrs(attrs))
    customer
  end

  @doc "Creates a contract (and, unless given, its customer)."
  def contract_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:customer_id, fn -> customer_fixture(scope).id end)
      |> Map.put_new(:external_reference, unique_contract_reference())
      |> Map.put_new(:currency, "DKK")
      |> Map.put_new(:start_date, ~D[2026-01-01])

    {:ok, contract} = Contracts.create_contract(scope, attrs)
    contract
  end

  @doc """
  Starts a subscription (and, unless given, its contract). Defaults to
  starting today, i.e. `:active`.
  """
  def subscription_fixture(scope, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new_lazy(:contract_id, fn -> contract_fixture(scope).id end)
      |> Map.put_new(:external_id, unique_subscription_external_id())
      |> Map.put_new(:plan_version_id, Ecto.UUID.generate())
      |> Map.put_new(:quantity, Decimal.new(1))
      |> Map.put_new(:start_date, Date.utc_today())

    {:ok, subscription} = Contracts.start_subscription(scope, attrs)
    subscription
  end

  @doc "Complete point-in-time charge instance attrs; override any key."
  def valid_charge_instance_attrs(contract, attrs \\ %{}) do
    attrs
    |> Map.new()
    |> Map.put_new(:external_id, unique_charge_external_id())
    |> Map.put_new(:contract_id, contract.id)
    |> Map.put_new(:product_id, Ecto.UUID.generate())
    |> Map.put_new(:product_version, 1)
    |> Map.put_new(:eligible_on, Date.utc_today())
    |> Map.put_new(:recognition_mode, :point_in_time)
    |> then(fn attrs ->
      if Map.has_key?(attrs, :amount_minor) or Map.has_key?(attrs, :price_component_id) do
        attrs
      else
        attrs
        |> Map.put(:price_component_id, Ecto.UUID.generate())
        |> Map.put_new(:quantity, Decimal.new(1))
      end
    end)
  end

  @doc "Creates a pending charge instance on `contract`."
  def charge_instance_fixture(scope, contract, attrs \\ %{}) do
    {:ok, charge} =
      Contracts.create_charge_instance(scope, valid_charge_instance_attrs(contract, attrs))

    charge
  end
end
