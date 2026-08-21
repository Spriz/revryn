defmodule BillingCoreWeb.GraphQL.ViewerScopeTest do
  @moduledoc """
  Authentication, viewer resolution, and explicit scope selection
  (SPEC §14.2): possession of an ID never grants access.
  """

  use BillingCoreWeb.GraphQLCase, async: true

  describe "viewer" do
    test "returns the authenticated principal with memberships", %{conn: conn} do
      %{user: user, organization: organization, team: team, token: token} = register_actor()

      query = """
      query Viewer {
        viewer {
          id
          platformAdmin
          organizationMemberships { organization { id name } roles }
          teamMemberships { team { id name organizationId } roles }
        }
      }
      """

      {200, %{"data" => %{"viewer" => viewer}}} = gql(conn, query, token: token)

      assert viewer["id"] == user.id
      assert viewer["platformAdmin"] == false

      assert [%{"organization" => %{"id" => org_id}, "roles" => ["organization_owner"]}] =
               viewer["organizationMemberships"]

      assert org_id == organization.id

      assert [%{"team" => %{"id" => team_id, "organizationId" => team_org_id}, "roles" => roles}] =
               viewer["teamMemberships"]

      assert team_id == team.id
      assert team_org_id == organization.id
      assert "finance_operator" in roles
    end

    test "unauthenticated request gets a stable error and no data leak", %{conn: conn} do
      {200, body} = gql(conn, "query { viewer { id } }")

      assert body["data"]["viewer"] == nil
      assert [%{"code" => "UNAUTHENTICATED"} | _] = body["errors"]
      refute inspect(body) =~ "Elixir."
    end
  end

  describe "scope selection (SPEC §14.2)" do
    test "a member reads team data, a non-member of the team is denied", %{conn: conn} do
      %{team: team, token: token, scope: scope} = register_actor()
      customer = customer_fixture(scope)

      query = """
      query Customer($teamId: ID!, $id: ID!) {
        customer(teamId: $teamId, id: $id) { id externalId legalName }
      }
      """

      # The team member reads the customer.
      {200, %{"data" => %{"customer" => data}}} =
        gql(conn, query, token: token, variables: %{"teamId" => team.id, "id" => customer.id})

      assert data["id"] == customer.id
      assert data["legalName"] == "Acme ApS"

      # A user from a different organization holding the same IDs is denied
      # identically to a nonexistent team: no scope, no detail leak.
      %{token: outsider_token} = register_actor()

      {200, body} =
        gql(conn, query,
          token: outsider_token,
          variables: %{"teamId" => team.id, "id" => customer.id}
        )

      assert body["data"]["customer"] == nil
      assert [%{"code" => "UNAUTHORIZED"} | _] = body["errors"]
    end

    test "an organization member without team membership cannot read team data", %{conn: conn} do
      %{organization: organization, team: team, scope: scope} = register_actor()
      customer = customer_fixture(scope)

      # Active organization membership but NO team membership: team roles
      # never derive from organization roles (SPEC §13.4).
      org_only_user = user_fixture()
      organization_membership_fixture(organization, org_only_user, [:organization_admin])
      {token, _session} = BillingCore.Identity.create_session(org_only_user)

      query = """
      query Customer($teamId: ID!, $id: ID!) {
        customer(teamId: $teamId, id: $id) { id }
      }
      """

      {200, body} =
        gql(conn, query, token: token, variables: %{"teamId" => team.id, "id" => customer.id})

      assert body["data"]["customer"] == nil
      assert [%{"code" => "UNAUTHORIZED"} | _] = body["errors"]
    end

    test "organizations and teams listings follow memberships", %{conn: conn} do
      %{organization: organization, team: team, token: token} = register_actor()

      query = """
      query Orgs($organizationId: ID!) {
        organizations { id name }
        teams(organizationId: $organizationId) { id name baseCurrency }
      }
      """

      {200, %{"data" => data}} =
        gql(conn, query, token: token, variables: %{"organizationId" => organization.id})

      assert [%{"id" => org_id}] = data["organizations"]
      assert org_id == organization.id
      assert Enum.any?(data["teams"], &(&1["id"] == team.id))
    end
  end
end
