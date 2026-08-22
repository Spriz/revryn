defmodule BillingCore.ScopeTest do
  use ExUnit.Case, async: true

  alias BillingCore.Scope

  @team_id "00000000-0000-0000-0000-000000000021"
  @organization_id "00000000-0000-0000-0000-000000000031"

  defp scope(attrs \\ []) do
    struct!(Scope, Keyword.merge([principal_type: :user], attrs))
  end

  describe "team_scoped?/1" do
    test "true only when a team is resolved" do
      assert Scope.team_scoped?(scope(team: %{id: @team_id}))
      refute Scope.team_scoped?(scope())
    end
  end

  describe "has_team_role?/2" do
    test "matches a single wanted role" do
      s = scope(team_roles: [:billing_admin])
      assert Scope.has_team_role?(s, :billing_admin)
      refute Scope.has_team_role?(s, :auditor)
    end

    test "matches any of a wanted role list" do
      s = scope(team_roles: [:auditor])
      assert Scope.has_team_role?(s, [:billing_admin, :auditor])
      refute Scope.has_team_role?(s, [:billing_admin, :finance_operator])
      refute Scope.has_team_role?(s, [])
    end
  end

  describe "has_organization_role?/2" do
    test "matches a single wanted role" do
      s = scope(organization_roles: [:organization_admin])
      assert Scope.has_organization_role?(s, :organization_admin)
      refute Scope.has_organization_role?(s, :organization_owner)
    end

    test "matches any of a wanted role list" do
      s = scope(organization_roles: [:organization_member])
      assert Scope.has_organization_role?(s, [:organization_owner, :organization_member])
      refute Scope.has_organization_role?(s, [:organization_owner, :organization_admin])
    end
  end

  describe "team_id!/1" do
    test "returns the resolved team id" do
      assert Scope.team_id!(scope(team: %{id: @team_id})) == @team_id
    end

    test "raises without a resolved team" do
      assert_raise ArgumentError, "operation requires a team-resolved scope", fn ->
        Scope.team_id!(scope())
      end
    end

    test "raises when the resolved team has no id" do
      assert_raise ArgumentError, fn -> Scope.team_id!(scope(team: %{id: nil})) end
    end
  end

  describe "organization_id!/1" do
    test "returns the resolved organization id" do
      assert Scope.organization_id!(scope(organization: %{id: @organization_id})) ==
               @organization_id
    end

    test "raises without a resolved organization" do
      assert_raise ArgumentError, "operation requires an organization-resolved scope", fn ->
        Scope.organization_id!(scope())
      end
    end
  end
end
