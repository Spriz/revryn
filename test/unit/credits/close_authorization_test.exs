defmodule BillingCore.Credits.Close.AuthorizationTest do
  use ExUnit.Case, async: true

  alias BillingCore.Credits.Close.Authorization
  alias BillingCore.Scope

  @team_id "00000000-0000-0000-0000-000000000021"

  test "requires a resolved same-team finance role for writes" do
    close = %{team_id: @team_id}

    assert :ok =
             Authorization.authorize(
               %Scope{
                 principal_type: :user,
                 team: %{id: @team_id},
                 team_roles: [:finance_operator]
               },
               close,
               :write
             )

    assert {:error, :unauthorized} =
             Authorization.authorize(
               %Scope{principal_type: :user, team: %{id: @team_id}, team_roles: [:auditor]},
               close,
               :write
             )
  end

  test "does not trust a matching close ID without matching scope team" do
    assert {:error, :unauthorized} =
             Authorization.authorize(
               %Scope{
                 principal_type: :user,
                 team: %{id: "00000000-0000-0000-0000-000000000022"},
                 team_roles: [:finance_operator]
               },
               %{team_id: @team_id},
               :read
             )
  end
end
