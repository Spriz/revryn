defmodule BillingCore.Workflows.CustomerManagementTest do
  @moduledoc """
  Customer maintenance as documentation (BC-US-030, SPEC §13.3): customers
  are upserted by team-scoped external ID, every change of the canonical
  facts appends an immutable version snapshot, unchanged upserts are no-ops,
  and history can never be rewritten.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.Audit
  alias BillingCore.Contracts
  alias BillingCore.Contracts.CustomerVersion
  alias BillingCore.Outbox

  import BillingCore.ContractsFixtures

  setup do
    %{scope: billing_scope_fixture()}
  end

  describe "creating a customer" do
    test "the first upsert writes the customer and immutable version 1", %{scope: scope} do
      attrs = valid_customer_attrs(%{legal_name: "Nordisk Handel A/S", country: "DK"})

      assert {:ok, %{customer: customer, version: version}} =
               Contracts.upsert_customer(scope, attrs)

      assert customer.team_id == scope.team.id
      assert customer.external_id == attrs.external_id
      assert customer.status == :active
      assert customer.current_version == 1

      # version 1 carries the full snapshot plus its canonical hash
      assert version.version == 1
      assert version.customer_id == customer.id
      assert version.legal_name == "Nordisk Handel A/S"
      assert version.country == "DK"
      assert version.snapshot["legal_name"] == "Nordisk Handel A/S"
      assert version.snapshot["status"] == "active"
      assert version.content_hash =~ ~r/^[0-9a-f]{64}$/

      # evidenced in the same transaction
      assert "contracts.customer.version_created" in audit_events(customer.id)
      assert "customer.version_created.v1" in outbox_events(customer.id)
    end

    test "invalid facts are rejected as a whole — no partial customer", %{scope: scope} do
      attrs = valid_customer_attrs(%{country: "Denmark"})

      assert {:error, changeset} = Contracts.upsert_customer(scope, attrs)
      assert %{country: [_message]} = errors_on(changeset)
      assert {:ok, []} = Contracts.list_customers(scope)
    end
  end

  describe "updating a customer" do
    test "changed facts append version 2 while version 1 stays intact", %{scope: scope} do
      attrs = valid_customer_attrs(%{legal_name: "Old Name ApS"})
      {:ok, %{customer: customer, version: v1}} = Contracts.upsert_customer(scope, attrs)

      assert {:ok, %{customer: updated, version: v2}} =
               Contracts.upsert_customer(scope, %{attrs | legal_name: "New Name ApS"})

      assert updated.id == customer.id
      assert updated.current_version == 2
      assert v2.version == 2
      assert v2.legal_name == "New Name ApS"
      refute v2.content_hash == v1.content_hash

      # the full history remains, oldest first, version 1 untouched
      assert {:ok, [history_v1, history_v2]} =
               Contracts.list_customer_versions(scope, updated)

      assert history_v1.id == v1.id
      assert history_v1.legal_name == "Old Name ApS"
      assert history_v2.id == v2.id

      # one event per version
      assert Enum.count(outbox_events(customer.id), &(&1 == "customer.version_created.v1")) == 2
    end

    test "customer versions reject UPDATE at the database", %{scope: scope} do
      {:ok, %{version: v1}} = Contracts.upsert_customer(scope, valid_customer_attrs())

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.update_all(
          from(v in CustomerVersion, where: v.id == ^v1.id),
          set: [legal_name: "Mutated"]
        )
      end
    end

    test "customer versions reject DELETE at the database", %{scope: scope} do
      {:ok, %{version: v1}} = Contracts.upsert_customer(scope, valid_customer_attrs())

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.delete_all(from(v in CustomerVersion, where: v.id == ^v1.id))
      end
    end

    test "an unchanged upsert is an idempotent no-op", %{scope: scope} do
      attrs = valid_customer_attrs()

      {:ok, %{customer: customer, version: %{version: 1}}} =
        Contracts.upsert_customer(scope, attrs)

      assert {:ok, %{customer: unchanged, version: nil}} =
               Contracts.upsert_customer(scope, attrs)

      assert unchanged.id == customer.id
      assert unchanged.current_version == 1
      assert {:ok, [_only_v1]} = Contracts.list_customer_versions(scope, customer)
      assert Enum.count(outbox_events(customer.id), &(&1 == "customer.version_created.v1")) == 1
    end
  end

  describe "team isolation and authorization" do
    test "the same external ID is unique per team but reusable across teams", %{scope: scope} do
      other_scope = billing_scope_fixture()
      external_id = unique_customer_external_id()

      customer_a = customer_fixture(scope, %{external_id: external_id, legal_name: "Team A ApS"})

      customer_b =
        customer_fixture(other_scope, %{external_id: external_id, legal_name: "Team B ApS"})

      # two independent aggregates, invisible across the team boundary
      refute customer_a.id == customer_b.id
      assert {:error, :not_found} = Contracts.get_customer(other_scope, customer_a.id)
      assert {:ok, listed} = Contracts.list_customers(other_scope)
      assert Enum.map(listed, & &1.id) == [customer_b.id]
    end

    test "mutations require billing_admin or team_admin; read roles can read", %{scope: scope} do
      customer = customer_fixture(scope)
      auditor = team_scope_fixture(scope.organization, scope.team, [:auditor])

      assert {:error, :unauthorized} =
               Contracts.upsert_customer(auditor, valid_customer_attrs())

      assert {:ok, %{id: id}} = Contracts.get_customer(auditor, customer.id)
      assert id == customer.id
    end
  end

  defp audit_events(aggregate_id) do
    Repo.all(from e in Audit.Entry, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end

  defp outbox_events(aggregate_id) do
    Repo.all(from e in Outbox.Event, where: e.aggregate_id == ^aggregate_id, select: e.event_type)
  end
end
