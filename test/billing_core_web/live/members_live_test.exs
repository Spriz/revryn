defmodule BillingCoreWeb.MembersLiveTest do
  use BillingCoreWeb.ConnCase, async: true

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures
  import BillingCoreWeb.WebHelpers
  import Phoenix.LiveViewTest

  alias BillingCore.{Identity, Orgs, Repo}
  alias BillingCore.Orgs.TeamMembership

  setup %{conn: conn} do
    %{organization: organization, team: team} = organization_fixture()
    admin = user_fixture()
    organization_membership_fixture(organization, admin, [:organization_admin])
    team_membership_fixture(team, admin, [:team_admin])

    member = user_fixture()
    organization_membership_fixture(organization, member, [:organization_member])
    membership = team_membership_fixture(team, member, [:auditor])

    %{
      conn: conn,
      organization: organization,
      team: team,
      admin: admin,
      member: member,
      membership: membership
    }
  end

  test "an admin changes roles and removes a member — audited domain effects",
       %{conn: conn, team: team, admin: admin, membership: membership} do
    {:ok, view, _html} =
      conn |> log_in_user(admin) |> live(~p"/teams/#{team.id}/members")

    assert has_element?(view, "#team-members")
    assert has_element?(view, "#roles-form-#{membership.id}")

    view
    |> element("#roles-form-#{membership.id}")
    |> render_change(%{"membership_id" => membership.id, "roles" => ["auditor", "billing_admin"]})

    assert Enum.sort(Repo.reload!(membership).roles) == [:auditor, :billing_admin]

    view |> element("#remove-member-#{membership.id}") |> render_click()
    assert Repo.reload!(membership).status == :removed
  end

  test "a non-admin sees roles read-only and cannot mutate",
       %{conn: conn, team: team, member: member, membership: membership} do
    {:ok, view, _html} =
      conn |> log_in_user(member) |> live(~p"/teams/#{team.id}/members")

    refute has_element?(view, "#roles-form-#{membership.id}")
    refute has_element?(view, "#remove-member-#{membership.id}")
    refute has_element?(view, "#invite-form")

    # Even a crafted event is refused by the scoped domain command.
    render_change(view, "change_roles", %{
      "membership_id" => membership.id,
      "roles" => ["team_admin"]
    })

    assert Repo.reload!(membership).roles == [:auditor]
  end

  test "the invite loop: create, show single-use link, pending list, revoke",
       %{conn: conn, team: team, admin: admin} do
    {:ok, view, _html} =
      conn |> log_in_user(admin) |> live(~p"/teams/#{team.id}/members")

    view
    |> form("#invite-form", %{
      "invite" => %{"email" => "newcomer@example.com", "roles" => ["finance_operator"]}
    })
    |> render_submit()

    assert has_element?(view, "#invite-link", "/invitations/")
    assert has_element?(view, "#pending-invitations", "newcomer@example.com")

    # The link works end to end for the invited identity.
    link = view |> element("#invite-link code") |> render() |> extract_path()
    {:ok, newcomer} = Identity.register_user("newcomer@example.com")

    assert {:error, {:live_redirect, %{to: destination}}} =
             conn |> log_in_user(newcomer) |> live(link)

    assert destination == "/teams/#{team.id}"

    assert Repo.get_by!(TeamMembership, team_id: team.id, user_id: newcomer.id).roles == [
             :finance_operator
           ]

    # Revoking a second pending invitation removes it from the list.
    view
    |> form("#invite-form", %{
      "invite" => %{"email" => "second@example.com", "roles" => ["auditor"]}
    })
    |> render_submit()

    {:ok, invitations} =
      Orgs.list_invitations(%BillingCore.Scope{
        principal_type: :user,
        user: admin,
        organization: Repo.get!(BillingCore.Orgs.Organization, team.organization_id),
        organization_roles: [:organization_admin]
      })

    invitation = Enum.find(invitations, &(&1.email == "second@example.com"))

    view |> element("#revoke-invitation-#{invitation.id}") |> render_click()
    refute has_element?(view, "#revoke-invitation-#{invitation.id}")
  end

  defp extract_path(html) do
    [_full, path] = Regex.run(~r{(/invitations/[A-Za-z0-9_-]+)}, html)
    path
  end
end
