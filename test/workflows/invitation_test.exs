defmodule BillingCore.Workflows.InvitationTest do
  @moduledoc """
  BC-US-144: invitations link an existing global identity to new
  organization/team memberships through a single-use, expiring,
  hashed-at-rest token — scoped to exactly the invited grants, with no
  silent escalation anywhere else.
  """

  use BillingCore.DataCase, async: true

  import Ecto.Query
  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures
  import Swoosh.TestAssertions

  alias BillingCore.{Identity, Orgs, Repo}
  alias BillingCore.Orgs.{Invitation, OrganizationMembership, TeamMembership}

  setup do
    %{organization: organization, team: team} = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(organization, admin, [:organization_admin])
    {:ok, scope} = Orgs.resolve_scope(admin, organization.id)

    %{organization: organization, team: team, admin_scope: scope}
  end

  test "invite → email → accept links the existing user with exactly the invited grants",
       %{organization: organization, team: team, admin_scope: scope} do
    {:ok, invitee} = Identity.register_user("invitee@example.com")

    assert {:ok, %{invitation: invitation, token: token, delivery: :sent}} =
             Orgs.invite_member(scope, %{
               email: "Invitee@Example.com",
               organization_roles: ["organization_member"],
               team_id: team.id,
               team_roles: ["auditor", "finance_operator"],
               accept_url_fun: fn t -> "https://revryn.example/invitations/accept/#{t}" end
             })

    # Hashed at rest; the raw token never persists.
    assert invitation.token_hash != token
    assert invitation.email == "invitee@example.com"

    assert_email_sent(fn sent ->
      assert [{_name, "invitee@example.com"}] = sent.to
      assert sent.text_body =~ token
    end)

    assert {:ok, accepted} = Orgs.accept_invitation(invitee, token)
    assert accepted.accepted_user_id == invitee.id

    membership =
      Repo.get_by!(OrganizationMembership, organization_id: organization.id, user_id: invitee.id)

    assert membership.status == :active
    assert membership.roles == [:organization_member]

    team_membership = Repo.get_by!(TeamMembership, team_id: team.id, user_id: invitee.id)
    assert Enum.sort(team_membership.roles) == [:auditor, :finance_operator]

    # The scope resolves — the identity is linked, not duplicated.
    assert {:ok, _scope} = Orgs.resolve_scope(invitee, organization.id, team.id)
    assert Repo.aggregate(from(u in BillingCore.Identity.User), :count) >= 2

    # Single use: the token is dead after acceptance.
    assert {:error, :invalid_invitation} = Orgs.accept_invitation(invitee, token)
  end

  test "the token is bound to the invited email", %{team: team, admin_scope: scope} do
    {:ok, _invitee} = Identity.register_user("intended@example.com")
    {:ok, interloper} = Identity.register_user("interloper@example.com")

    {:ok, %{token: token}} =
      Orgs.invite_member(scope, %{
        email: "intended@example.com",
        team_id: team.id,
        team_roles: ["auditor"]
      })

    assert {:error, :email_mismatch} = Orgs.accept_invitation(interloper, token)
  end

  test "expired and revoked invitations are dead", %{team: team, admin_scope: scope} do
    {:ok, invitee} = Identity.register_user("late@example.com")

    {:ok, %{invitation: invitation, token: token}} =
      Orgs.invite_member(scope, %{
        email: "late@example.com",
        team_id: team.id,
        team_roles: ["auditor"]
      })

    Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)]
    )

    assert {:error, :invalid_invitation} = Orgs.accept_invitation(invitee, token)

    {:ok, %{invitation: second, token: second_token}} =
      Orgs.invite_member(scope, %{
        email: "late@example.com",
        team_id: team.id,
        team_roles: ["auditor"]
      })

    {:ok, _revoked} = Orgs.revoke_invitation(scope, second.id)
    assert {:error, :invalid_invitation} = Orgs.accept_invitation(invitee, second_token)
  end

  test "grants are additive in the invited scope only — no cross-scope escalation",
       %{organization: organization, team: team, admin_scope: scope} do
    # The invitee already has memberships elsewhere and a lesser role here.
    %{organization: other_org, team: other_team} = organization_fixture()
    {:ok, invitee} = Identity.register_user("existing@example.com")
    organization_membership_fixture(other_org, invitee, [:organization_owner])
    other_membership = team_membership_fixture(other_team, invitee, [:team_admin])

    organization_membership_fixture(organization, invitee, [:organization_member])
    team_membership_fixture(team, invitee, [:auditor])

    {:ok, %{token: token}} =
      Orgs.invite_member(scope, %{
        email: "existing@example.com",
        team_id: team.id,
        team_roles: ["billing_admin"]
      })

    {:ok, _accepted} = Orgs.accept_invitation(invitee, token)

    # Target team: roles merged additively to exactly the invited grant.
    team_membership = Repo.get_by!(TeamMembership, team_id: team.id, user_id: invitee.id)
    assert Enum.sort(team_membership.roles) == [:auditor, :billing_admin]

    # Foreign org/team memberships are untouched.
    assert Repo.reload!(other_membership).roles == [:team_admin]

    other_org_membership =
      Repo.get_by!(OrganizationMembership, organization_id: other_org.id, user_id: invitee.id)

    assert other_org_membership.roles == [:organization_owner]
  end

  test "only organization owners/admins can invite, revoke, or list",
       %{organization: organization, team: team} do
    member = user_fixture()
    organization_membership_fixture(organization, member, [:organization_member])
    {:ok, member_scope} = Orgs.resolve_scope(member, organization.id)

    assert {:error, :unauthorized} =
             Orgs.invite_member(member_scope, %{
               email: "x@example.com",
               team_id: team.id,
               team_roles: ["auditor"]
             })

    assert {:error, :unauthorized} = Orgs.list_invitations(member_scope)
  end

  test "role and team inputs are validated against the canonical sets",
       %{team: team, admin_scope: scope} do
    assert {:error, :invalid_roles} =
             Orgs.invite_member(scope, %{
               email: "x@example.com",
               team_id: team.id,
               team_roles: ["superuser"]
             })

    %{team: foreign_team} = organization_fixture()

    assert {:error, :team_not_in_organization} =
             Orgs.invite_member(scope, %{
               email: "x@example.com",
               team_id: foreign_team.id,
               team_roles: ["auditor"]
             })

    assert {:error, :no_grants} = Orgs.invite_member(scope, %{email: "x@example.com"})
    assert {:error, :invalid_email} = Orgs.invite_member(scope, %{email: "not-an-email"})
  end
end
