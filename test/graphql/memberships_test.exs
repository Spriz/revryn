defmodule BillingCoreWeb.GraphQL.MembershipsTest do
  @moduledoc """
  SPEC §14.5 organizations-and-membership contract breadth (BC-TASK-088):
  membership directories, role changes with last-owner protection, team
  membership administration under INV-024 (no implicit team access), and
  team rename/archive lifecycle with last-team protection (INV-033).
  """

  use BillingCoreWeb.GraphQLCase, async: false

  alias BillingCore.{Identity, Orgs, Repo}
  alias BillingCore.Orgs.{Team, TeamMembership}

  setup do
    ctx = register_actor([:team_admin])

    # A second global identity holding plain organization membership only —
    # the raw material for team grants and role changes.
    {:ok, member} = Identity.register_user("fjeldmark-member@example.com")

    {:ok, org_membership} =
      Orgs.add_organization_member(ctx.organization, member, [:organization_member])

    %{ctx: ctx, member: member, org_membership: org_membership}
  end

  describe "membership directories" do
    test "organization directory lists members with emails for owners", %{
      conn: conn,
      ctx: ctx,
      member: member
    } do
      query = """
      query Members($organizationId: ID!) {
        organizationMemberships(organizationId: $organizationId) {
          userId email roles status
        }
      }
      """

      {200, %{"data" => %{"organizationMemberships" => rows}}} =
        gql(conn, query,
          token: ctx.token,
          variables: %{"organizationId" => ctx.organization.id}
        )

      assert Enum.any?(
               rows,
               &(&1["userId"] == ctx.user.id and "organization_owner" in &1["roles"])
             )

      assert Enum.any?(
               rows,
               &(&1["userId"] == member.id and &1["email"] == "fjeldmark-member@example.com" and
                   &1["roles"] == ["organization_member"])
             )

      assert Enum.all?(rows, &(&1["status"] == "active"))
    end

    test "plain organization members cannot read the organization directory", %{
      conn: conn,
      ctx: ctx,
      member: member
    } do
      {token, _session} = Identity.create_session(member)

      query = """
      query Members($organizationId: ID!) {
        organizationMemberships(organizationId: $organizationId) { userId }
      }
      """

      {200, %{"errors" => [error]}} =
        gql(conn, query, token: token, variables: %{"organizationId" => ctx.organization.id})

      assert error["code"] == "UNAUTHORIZED"
    end

    # Not covered on purpose: the resolver's own `{:error, :unauthorized}`
    # branch for teamMemberships cannot fire over HTTP — the field requires
    # teamId, so a resolved scope is always team-scoped; outsiders are
    # stopped earlier by scope resolution (asserted below).
    test "team directory is readable by team members and closed to outsiders", %{
      conn: conn,
      ctx: ctx,
      member: member
    } do
      query = """
      query Members($teamId: ID!) {
        teamMemberships(teamId: $teamId) { userId email roles status }
      }
      """

      {200, %{"data" => %{"teamMemberships" => [row]}}} =
        gql(conn, query, token: ctx.token, variables: %{"teamId" => ctx.team.id})

      assert row["userId"] == ctx.user.id
      assert row["roles"] == ["team_admin"]

      # An organization member without a team membership is not in scope.
      {member_token, _session} = Identity.create_session(member)

      {200, %{"errors" => [error]}} =
        gql(conn, query, token: member_token, variables: %{"teamId" => ctx.team.id})

      assert error["code"] == "UNAUTHORIZED"
    end
  end

  describe "team membership administration" do
    @add_mutation """
    mutation Add($input: AddTeamMemberInput!) {
      addTeamMember(input: $input) {
        __typename
        ... on AddTeamMemberSuccess { membership { id userId email roles status } }
        ... on ValidationProblem { code }
        ... on AuthorizationProblem { code }
      }
    }
    """

    test "addTeamMember grants an organization member explicit team roles", %{
      conn: conn,
      ctx: ctx,
      member: member
    } do
      {200, %{"data" => %{"addTeamMember" => payload}}} =
        gql(conn, @add_mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "userId" => member.id,
              "teamRoles" => ["auditor"],
              "clientMutationId" => "add-1"
            }
          }
        )

      assert %{"membership" => record} = payload
      assert record["userId"] == member.id
      assert record["email"] == "fjeldmark-member@example.com"
      assert record["roles"] == ["auditor"]

      membership = Repo.get_by!(TeamMembership, team_id: ctx.team.id, user_id: member.id)
      assert membership.roles == [:auditor]
    end

    test "addTeamMember refuses a user without organization membership (INV-024)", %{
      conn: conn,
      ctx: ctx
    } do
      {:ok, outsider} = Identity.register_user("askefjord-outsider@example.com")

      {200, %{"data" => %{"addTeamMember" => payload}}} =
        gql(conn, @add_mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "userId" => outsider.id,
              "teamRoles" => ["auditor"],
              "clientMutationId" => "add-2"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "NOT_ORGANIZATION_MEMBER"
    end

    test "changeTeamRoles and removeTeamMember round-trip", %{
      conn: conn,
      ctx: ctx,
      member: member
    } do
      {:ok, membership} = Orgs.add_team_member(ctx.team, member, [:auditor])

      change = """
      mutation Change($input: ChangeTeamRolesInput!) {
        changeTeamRoles(input: $input) {
          __typename
          ... on ChangeTeamRolesSuccess { membership { roles } }
          ... on ValidationProblem { code }
          ... on AuthorizationProblem { code }
        }
      }
      """

      {200, %{"data" => %{"changeTeamRoles" => changed}}} =
        gql(conn, change,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "membershipId" => membership.id,
              "teamRoles" => ["billing_admin", "finance_operator"],
              "clientMutationId" => "roles-1"
            }
          }
        )

      assert changed["membership"]["roles"] == ["billing_admin", "finance_operator"]

      remove = """
      mutation Remove($input: RemoveTeamMemberInput!) {
        removeTeamMember(input: $input) {
          __typename
          ... on RemoveTeamMemberSuccess { membership { status } }
          ... on ValidationProblem { code }
          ... on AuthorizationProblem { code }
        }
      }
      """

      {200, %{"data" => %{"removeTeamMember" => removed}}} =
        gql(conn, remove,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "membershipId" => membership.id,
              "clientMutationId" => "remove-1"
            }
          }
        )

      # The history row is retained with removed status (SPEC §13.3).
      assert removed["membership"]["status"] == "removed"
      assert Repo.get!(TeamMembership, membership.id).status == :removed
    end

    test "membership commands against missing or malformed IDs are typed NOT_FOUND", %{
      conn: conn,
      ctx: ctx
    } do
      change = """
      mutation Change($input: ChangeTeamRolesInput!) {
        changeTeamRoles(input: $input) {
          __typename
          ... on ValidationProblem { code }
        }
      }
      """

      # A non-UUID never reaches the database.
      {200, %{"data" => %{"changeTeamRoles" => malformed}}} =
        gql(conn, change,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "membershipId" => "not-a-uuid",
              "teamRoles" => ["auditor"],
              "clientMutationId" => "roles-x"
            }
          }
        )

      assert malformed["__typename"] == "ValidationProblem"
      assert malformed["code"] == "NOT_FOUND"

      remove = """
      mutation Remove($input: RemoveTeamMemberInput!) {
        removeTeamMember(input: $input) {
          __typename
          ... on ValidationProblem { code }
        }
      }
      """

      {200, %{"data" => %{"removeTeamMember" => missing}}} =
        gql(conn, remove,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "membershipId" => Ecto.UUID.generate(),
              "clientMutationId" => "remove-x"
            }
          }
        )

      assert missing["__typename"] == "ValidationProblem"
      assert missing["code"] == "NOT_FOUND"
    end

    test "non-admin team members cannot administer memberships", %{
      conn: conn,
      ctx: ctx,
      member: member
    } do
      {:ok, _membership} = Orgs.add_team_member(ctx.team, member, [:auditor])
      {member_token, _session} = Identity.create_session(member)

      {200, %{"data" => %{"addTeamMember" => payload}}} =
        gql(conn, @add_mutation,
          token: member_token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "userId" => member.id,
              "teamRoles" => ["team_admin"],
              "clientMutationId" => "add-3"
            }
          }
        )

      assert payload["__typename"] == "AuthorizationProblem"
    end
  end

  describe "organization role administration" do
    @change_org_roles """
    mutation Change($input: ChangeOrganizationRolesInput!) {
      changeOrganizationRoles(input: $input) {
        __typename
        ... on ChangeOrganizationRolesSuccess { membership { userId roles } }
        ... on ValidationProblem { code }
        ... on AuthorizationProblem { code }
      }
    }
    """

    test "promotes a member to organization admin", %{
      conn: conn,
      ctx: ctx,
      member: member,
      org_membership: org_membership
    } do
      {200, %{"data" => %{"changeOrganizationRoles" => payload}}} =
        gql(conn, @change_org_roles,
          token: ctx.token,
          variables: %{
            "input" => %{
              "organizationId" => ctx.organization.id,
              "membershipId" => org_membership.id,
              "organizationRoles" => ["organization_admin"],
              "clientMutationId" => "org-roles-1"
            }
          }
        )

      assert payload["membership"] == %{"userId" => member.id, "roles" => ["organization_admin"]}
    end

    test "demoting the last active owner is refused", %{conn: conn, ctx: ctx} do
      owner_membership =
        Repo.get_by!(BillingCore.Orgs.OrganizationMembership,
          organization_id: ctx.organization.id,
          user_id: ctx.user.id
        )

      {200, %{"data" => %{"changeOrganizationRoles" => payload}}} =
        gql(conn, @change_org_roles,
          token: ctx.token,
          variables: %{
            "input" => %{
              "organizationId" => ctx.organization.id,
              "membershipId" => owner_membership.id,
              "organizationRoles" => ["organization_member"],
              "clientMutationId" => "org-roles-2"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "LAST_OWNER"
    end
  end

  describe "team lifecycle" do
    test "renameTeam keeps UUID and slug stable", %{conn: conn, ctx: ctx} do
      mutation = """
      mutation Rename($input: RenameTeamInput!) {
        renameTeam(input: $input) {
          __typename
          ... on RenameTeamSuccess { team { id name slug } }
          ... on ValidationProblem { code }
          ... on AuthorizationProblem { code }
        }
      }
      """

      {200, %{"data" => %{"renameTeam" => payload}}} =
        gql(conn, mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "name" => "Nordkap Finance",
              "clientMutationId" => "rename-1"
            }
          }
        )

      assert payload["team"]["id"] == ctx.team.id
      assert payload["team"]["name"] == "Nordkap Finance"
      assert payload["team"]["slug"] == ctx.team.slug
    end

    test "renameTeam with a blank name is a field-level ValidationProblem", %{
      conn: conn,
      ctx: ctx
    } do
      mutation = """
      mutation Rename($input: RenameTeamInput!) {
        renameTeam(input: $input) {
          __typename
          ... on ValidationProblem { code fields { path } }
        }
      }
      """

      {200, %{"data" => %{"renameTeam" => payload}}} =
        gql(conn, mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "name" => "",
              "clientMutationId" => "rename-blank"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "VALIDATION_FAILED"
      assert Enum.any?(payload["fields"], &(&1["path"] == ["name"]))
    end

    @archive_mutation """
    mutation Archive($input: ArchiveTeamInput!) {
      archiveTeam(input: $input) {
        __typename
        ... on ArchiveTeamSuccess { team { id status } }
        ... on ValidationProblem { code }
        ... on AuthorizationProblem { code }
      }
    }
    """

    test "the final active team cannot be archived (INV-033)", %{conn: conn, ctx: ctx} do
      {200, %{"data" => %{"archiveTeam" => payload}}} =
        gql(conn, @archive_mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "organizationId" => ctx.organization.id,
              "targetTeamId" => ctx.team.id,
              "clientMutationId" => "archive-1"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "LAST_ACTIVE_TEAM"
    end

    test "an owner archives a second team without being a member of it", %{conn: conn, ctx: ctx} do
      {:ok, second} = Orgs.create_team(ctx.organization, %{name: "Vinterhavn"})

      {200, %{"data" => %{"archiveTeam" => payload}}} =
        gql(conn, @archive_mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "organizationId" => ctx.organization.id,
              "targetTeamId" => second.id,
              "clientMutationId" => "archive-2"
            }
          }
        )

      assert payload["team"] == %{"id" => second.id, "status" => "disabled"}
      assert Repo.get!(Team, second.id).status == :disabled
    end
  end
end
