defmodule BillingCore.Workflows.ScopeResolutionTest do
  @moduledoc """
  Scope resolution across conflicting roles (SPEC §6.3 example, §13.4,
  BC-US-143): one user is `organization_admin` in Org A and
  `organization_member` in Org B while simultaneously being
  `finance_operator` in Team A1, `auditor` in Team A2, `team_admin` in
  Team B1, and absent from Team B2. Every scope resolves independently and
  no role ever leaks across an organization or team boundary.
  """

  use BillingCore.DataCase, async: true

  alias BillingCore.{Orgs, Scope}

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  setup do
    user = user_fixture()

    %{organization: org_a, team: team_a1} = organization_fixture()
    team_a2 = team_fixture(org_a, %{name: "Team A2"})
    %{organization: org_b, team: team_b1} = organization_fixture()
    team_b2 = team_fixture(org_b, %{name: "Team B2"})

    organization_membership_fixture(org_a, user, [:organization_admin])
    organization_membership_fixture(org_b, user, [:organization_member])
    team_membership_fixture(team_a1, user, [:finance_operator])
    team_membership_fixture(team_a2, user, [:auditor])
    team_membership_fixture(team_b1, user, [:team_admin])
    # deliberately absent from team_b2

    %{
      user: user,
      org_a: org_a,
      org_b: org_b,
      team_a1: team_a1,
      team_a2: team_a2,
      team_b1: team_b1,
      team_b2: team_b2
    }
  end

  test "organization-only scopes carry organization roles and no team grants", ctx do
    assert {:ok, %Scope{} = scope_a} = Orgs.resolve_scope(ctx.user, ctx.org_a.id)
    assert scope_a.organization.id == ctx.org_a.id
    assert scope_a.organization_roles == [:organization_admin]
    assert scope_a.team == nil
    assert scope_a.team_roles == []
    refute Scope.team_scoped?(scope_a)

    assert {:ok, %Scope{} = scope_b} = Orgs.resolve_scope(ctx.user, ctx.org_b.id)
    assert scope_b.organization_roles == [:organization_member]
    assert scope_b.team_roles == []
  end

  test "each team scope carries exactly that team's roles", ctx do
    assert {:ok, scope_a1} = Orgs.resolve_scope(ctx.user, ctx.org_a.id, ctx.team_a1.id)
    assert scope_a1.organization_roles == [:organization_admin]
    assert scope_a1.team.id == ctx.team_a1.id
    assert scope_a1.team_roles == [:finance_operator]
    assert Scope.has_team_role?(scope_a1, :finance_operator)
    refute Scope.has_team_role?(scope_a1, [:auditor, :team_admin])

    assert {:ok, scope_a2} = Orgs.resolve_scope(ctx.user, ctx.org_a.id, ctx.team_a2.id)
    assert scope_a2.team_roles == [:auditor]

    assert {:ok, scope_b1} = Orgs.resolve_scope(ctx.user, ctx.org_b.id, ctx.team_b1.id)
    assert scope_b1.organization_roles == [:organization_member]
    assert scope_b1.team_roles == [:team_admin]
  end

  test "absence from a team denies access even to an organization member", ctx do
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, ctx.org_b.id, ctx.team_b2.id)
  end

  test "cross-organization team ID substitution fails in both directions (SPEC §13.4)", ctx do
    # user IS a member of both organizations and of both named teams —
    # the substitution must still fail because the team does not belong to
    # the named organization.
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, ctx.org_a.id, ctx.team_b1.id)
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, ctx.org_b.id, ctx.team_a1.id)
  end

  test "organization roles never grant team access", ctx do
    # org A's creator is organization_owner but has no membership in A2
    owner = owner_of(ctx.org_a)
    assert {:ok, scope} = Orgs.resolve_scope(owner, ctx.org_a.id)
    assert scope.organization_roles == [:organization_owner]

    assert {:error, :unauthorized} = Orgs.resolve_scope(owner, ctx.org_a.id, ctx.team_a2.id)
  end

  test "platform_admin never bypasses membership checks", ctx do
    admin = user_fixture(platform_admin: true)

    assert {:error, :unauthorized} = Orgs.resolve_scope(admin, ctx.org_a.id)
    assert {:error, :unauthorized} = Orgs.resolve_scope(admin, ctx.org_a.id, ctx.team_a1.id)

    # with an explicit membership the flag is carried on the scope only
    organization_membership_fixture(ctx.org_a, admin, [:organization_member])
    assert {:ok, scope} = Orgs.resolve_scope(admin, ctx.org_a.id)
    assert scope.platform_admin?
    assert scope.organization_roles == [:organization_member]
  end

  test "unknown, malformed, disabled, or suspended targets are all unauthorized", ctx do
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, Ecto.UUID.generate())
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, "not-a-uuid")

    assert {:error, :unauthorized} =
             Orgs.resolve_scope(ctx.user, ctx.org_a.id, Ecto.UUID.generate())

    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, ctx.org_a.id, "not-a-uuid")

    # disabled organization
    disabled_org =
      ctx.org_b |> Ecto.Changeset.change(status: :disabled) |> Repo.update!()

    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, disabled_org.id)

    # suspended organization membership
    membership =
      Repo.get_by!(BillingCore.Orgs.OrganizationMembership,
        organization_id: ctx.org_a.id,
        user_id: ctx.user.id
      )

    Repo.update!(Ecto.Changeset.change(membership, status: :suspended))
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, ctx.org_a.id)
    assert {:error, :unauthorized} = Orgs.resolve_scope(ctx.user, ctx.org_a.id, ctx.team_a1.id)
  end

  test "a disabled user resolves nothing", ctx do
    disabled = ctx.user |> Ecto.Changeset.change(status: :disabled) |> Repo.update!()
    assert {:error, :unauthorized} = Orgs.resolve_scope(disabled, ctx.org_a.id)
  end

  defp owner_of(organization) do
    membership =
      Repo.one!(
        from m in BillingCore.Orgs.OrganizationMembership,
          where:
            m.organization_id == ^organization.id and m.status == :active and
              fragment("? = ANY(?)", "organization_owner", m.roles)
      )

    BillingCore.Identity.get_user!(membership.user_id)
  end
end
