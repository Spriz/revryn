defmodule BillingCoreWeb.GraphQL.InvitationsTest do
  @moduledoc """
  BC-US-144 across the surfaces: the API invites, the mail platform
  delivers the single-use link, and the browser accept flow links the
  existing identity — with authorization and validity failures typed and
  non-leaking.
  """

  use BillingCoreWeb.GraphQLCase, async: false

  import Phoenix.LiveViewTest
  import BillingCoreWeb.WebHelpers

  alias BillingCore.{Identity, Repo}
  alias BillingCore.Orgs.TeamMembership

  setup %{conn: conn} do
    ctx = register_actor([:team_admin])

    # The actor owns the organization (organization_fixture owner), so the
    # scope carries an admin-capable organization role.
    %{conn: conn, ctx: ctx}
  end

  @invite_mutation """
  mutation Invite($input: InviteOrganizationMemberInput!) {
    inviteOrganizationMember(input: $input) {
      __typename
      ... on InviteOrganizationMemberSuccess {
        invitation { id email teamRoles pending }
        acceptUrl
      }
      ... on ValidationProblem { code }
      ... on AuthorizationProblem { code }
    }
  }
  """

  test "invite over the API, accept in the browser, roles land exactly", %{conn: conn, ctx: ctx} do
    {:ok, invitee} = Identity.register_user("nordlys-invitee@example.com")

    {200, %{"data" => %{"inviteOrganizationMember" => payload}}} =
      gql(conn, @invite_mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "email" => "nordlys-invitee@example.com",
            "teamId" => ctx.team.id,
            "teamRoles" => ["auditor"],
            "clientMutationId" => "invite-1"
          }
        }
      )

    assert %{"invitation" => invitation, "acceptUrl" => accept_url} = payload
    assert invitation["pending"] == true
    assert invitation["teamRoles"] == ["auditor"]

    # The invited person opens the mailed link in the browser; the
    # connected mount accepts and redirects to the granted team.
    %{path: path} = URI.parse(accept_url)

    assert {:error, {:live_redirect, %{to: destination}}} =
             conn |> log_in_user(invitee) |> live(path)

    assert destination == "/teams/#{ctx.team.id}"

    membership = Repo.get_by!(TeamMembership, team_id: ctx.team.id, user_id: invitee.id)
    assert membership.roles == [:auditor]

    # The listing shows the settled invitation; the token is single-use.
    query = """
    query Invitations($organizationId: ID!) {
      organizationInvitations(organizationId: $organizationId) { id pending acceptedAt }
    }
    """

    {200, %{"data" => %{"organizationInvitations" => [listed]}}} =
      gql(conn, query,
        token: ctx.token,
        variables: %{"organizationId" => ctx.organization.id}
      )

    assert listed["pending"] == false
    assert listed["acceptedAt"]
  end

  test "a plain organization member cannot invite", %{conn: conn, ctx: ctx} do
    member_ctx = register_actor([:team_admin])
    # member_ctx owns a different organization; against ctx's org they hold
    # nothing — and a mere organization_member of ctx's org is refused too.
    outsider_result =
      gql(conn, @invite_mutation,
        token: member_ctx.token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "email" => "x@example.com",
            "teamId" => ctx.team.id,
            "teamRoles" => ["auditor"],
            "clientMutationId" => "invite-x"
          }
        }
      )

    {200, %{"data" => %{"inviteOrganizationMember" => payload}}} = outsider_result
    assert payload["__typename"] == "AuthorizationProblem"

    member = BillingCore.IdentityFixtures.user_fixture()

    BillingCore.OrgsFixtures.organization_membership_fixture(ctx.organization, member, [
      :organization_member
    ])

    {member_token, _session} = Identity.create_session(member)

    {200, %{"data" => %{"inviteOrganizationMember" => member_payload}}} =
      gql(conn, @invite_mutation,
        token: member_token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "email" => "y@example.com",
            "teamId" => ctx.team.id,
            "teamRoles" => ["auditor"],
            "clientMutationId" => "invite-y"
          }
        }
      )

    assert member_payload["__typename"] == "AuthorizationProblem"
  end

  test "an invitation granting nothing is refused with a typed problem", %{conn: conn, ctx: ctx} do
    {200, %{"data" => %{"inviteOrganizationMember" => payload}}} =
      gql(conn, @invite_mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "email" => "granted-nothing@example.com",
            "clientMutationId" => "invite-empty"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "NO_GRANTS"
  end

  test "the invitation listing is closed to plain organization members", %{conn: conn, ctx: ctx} do
    member = BillingCore.IdentityFixtures.user_fixture()

    BillingCore.OrgsFixtures.organization_membership_fixture(ctx.organization, member, [
      :organization_member
    ])

    {member_token, _session} = Identity.create_session(member)

    query = """
    query Invitations($organizationId: ID!) {
      organizationInvitations(organizationId: $organizationId) { id }
    }
    """

    {200, body} =
      gql(conn, query,
        token: member_token,
        variables: %{"organizationId" => ctx.organization.id}
      )

    assert body["data"] == nil
    assert [%{"code" => "UNAUTHORIZED"} | _] = body["errors"]
  end

  test "revoking an invitation is single-shot; misses are typed NOT_FOUND", %{
    conn: conn,
    ctx: ctx
  } do
    {200, %{"data" => %{"inviteOrganizationMember" => invited}}} =
      gql(conn, @invite_mutation,
        token: ctx.token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "email" => "revoke-me@example.com",
            "teamId" => ctx.team.id,
            "teamRoles" => ["auditor"],
            "clientMutationId" => "invite-revoke"
          }
        }
      )

    invitation_id = invited["invitation"]["id"]

    revoke = """
    mutation Revoke($input: RevokeOrganizationInvitationInput!) {
      revokeOrganizationInvitation(input: $input) {
        __typename
        ... on RevokeOrganizationInvitationSuccess { invitation { id pending } }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"revokeOrganizationInvitation" => revoked}}} =
      gql(conn, revoke,
        token: ctx.token,
        variables: %{
          "input" => %{
            "organizationId" => ctx.organization.id,
            "invitationId" => invitation_id,
            "clientMutationId" => "revoke-1"
          }
        }
      )

    assert revoked["__typename"] == "RevokeOrganizationInvitationSuccess"
    assert revoked["invitation"]["pending"] == false

    # Revoking again — and revoking garbage — read identically.
    for dead_id <- [invitation_id, "not-a-uuid"] do
      {200, %{"data" => %{"revokeOrganizationInvitation" => missed}}} =
        gql(conn, revoke,
          token: ctx.token,
          variables: %{
            "input" => %{
              "organizationId" => ctx.organization.id,
              "invitationId" => dead_id,
              "clientMutationId" => "revoke-dead"
            }
          }
        )

      assert missed["__typename"] == "ValidationProblem"
      assert missed["code"] == "NOT_FOUND"
    end
  end

  test "a dead token reads identically to a missing one in the browser", %{conn: conn} do
    {:ok, wanderer} = Identity.register_user("wanderer@example.com")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> log_in_user(wanderer) |> live("/invitations/not-a-real-token")

    refute Repo.get_by(TeamMembership, user_id: wanderer.id)
  end
end
