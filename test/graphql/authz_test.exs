defmodule BillingCoreWeb.GraphQL.AuthzTest do
  @moduledoc """
  Field-level role checks for read-only listing resolvers (SPEC §14.2):
  read access follows team roles, the ERP command surface requires a
  finance role, and idempotency evidence records the acting principal.
  """

  use ExUnit.Case, async: true

  alias BillingCore.Scope
  alias BillingCoreWeb.GraphQL.Authz

  defp scope(attrs) do
    struct!(Scope, Map.merge(%{principal_type: :user}, Map.new(attrs)))
  end

  describe "can_read?/1" do
    test "every read-capable team role grants read access" do
      for role <- [:team_admin, :billing_admin, :finance_operator, :auditor, :integration_client] do
        assert Authz.can_read?(scope(team_roles: [role])),
               "expected #{role} to grant read access"
      end
    end

    test "a scope without team roles cannot read" do
      refute Authz.can_read?(scope(team_roles: []))
    end
  end

  describe "finance?/1" do
    test "only the finance_operator role reaches the ERP command surface" do
      assert Authz.finance?(scope(team_roles: [:finance_operator]))
      assert Authz.finance?(scope(team_roles: [:auditor, :finance_operator]))

      for role <- [:team_admin, :billing_admin, :auditor, :integration_client] do
        refute Authz.finance?(scope(team_roles: [role])),
               "expected #{role} to be denied the finance surface"
      end

      refute Authz.finance?(scope(team_roles: []))
    end
  end

  describe "principal_id/1" do
    test "a user principal is recorded as user:<id>" do
      assert Authz.principal_id(scope(user: %{id: "u-1"})) == "user:u-1"
    end

    test "a service principal is recorded as service:<id>" do
      assert Authz.principal_id(scope(principal_type: :service, service_credential: %{id: "s-1"})) ==
               "service:s-1"
    end

    test "a scope without a principal yields nil" do
      assert Authz.principal_id(scope([])) == nil
    end
  end
end
