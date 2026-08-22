defmodule BillingCoreWeb.GraphQL.Middleware.RequireScopeTest do
  @moduledoc """
  Explicit scope resolution before field resolution (SPEC §14.2,
  INV-024/025): possession of an ID never grants access, and every failure
  mode is indistinguishable from a nonexistent resource.
  """

  use BillingCore.DataCase, async: true

  import BillingCore.IdentityFixtures
  import BillingCore.OrgsFixtures

  alias Absinthe.Resolution
  alias BillingCore.Scope
  alias BillingCoreWeb.GraphQL.Middleware.RequireScope

  @correlation_id "9b3f0e18-6f0f-4bd1-8f7a-1f0a2b3c4d5e"

  setup do
    user = user_fixture()
    %{organization: organization, team: team} = organization_fixture(%{owner: user})
    %{user: user, organization: organization, team: team}
  end

  defp resolution(user, args) do
    %Resolution{
      context: %{current_user: user, correlation_id: @correlation_id},
      arguments: args
    }
  end

  describe "successful scope resolution" do
    test "teamId-only arguments resolve the team's organization and scope", ctx do
      result = RequireScope.call(resolution(ctx.user, %{team_id: ctx.team.id}), mode: :query)

      assert result.state == :unresolved
      assert %Scope{} = scope = result.context.scope
      assert scope.team.id == ctx.team.id
      assert scope.organization.id == ctx.organization.id
      assert scope.correlation_id == @correlation_id
    end

    test "organizationId-only arguments resolve an organization scope", ctx do
      result =
        RequireScope.call(
          resolution(ctx.user, %{organization_id: ctx.organization.id}),
          mode: :query
        )

      assert %Scope{team: nil} = scope = result.context.scope
      assert scope.organization.id == ctx.organization.id
    end

    test "mutation arguments are read from the input object", ctx do
      result =
        RequireScope.call(
          resolution(ctx.user, %{input: %{team_id: ctx.team.id, name: "x"}}),
          mode: :mutation
        )

      assert %Scope{} = result.context.scope
      assert result.context.scope.team.id == ctx.team.id
    end

    test "an already-resolved resolution passes through untouched", ctx do
      resolved = %Resolution{state: :resolved, value: :done, context: %{}}

      assert RequireScope.call(resolved, mode: :query) == resolved
      _ = ctx
    end
  end

  describe "query-mode failures" do
    test "no authenticated principal fails UNAUTHENTICATED", ctx do
      result = RequireScope.call(resolution(nil, %{team_id: ctx.team.id}), mode: :query)

      assert result.state == :resolved
      assert [%{code: "UNAUTHENTICATED"}] = result.errors
    end

    test "arguments without any scope ID fail UNAUTHORIZED", ctx do
      result = RequireScope.call(resolution(ctx.user, %{id: "some-row"}), mode: :query)

      assert [%{code: "UNAUTHORIZED"}] = result.errors
    end

    test "a non-UUID teamId fails identically to an unknown team", ctx do
      result = RequireScope.call(resolution(ctx.user, %{team_id: "not-a-uuid"}), mode: :query)

      assert [%{code: "UNAUTHORIZED"}] = result.errors
    end

    test "a well-formed but nonexistent teamId fails UNAUTHORIZED", ctx do
      result =
        RequireScope.call(
          resolution(ctx.user, %{team_id: Ecto.UUID.generate()}),
          mode: :query
        )

      assert [%{code: "UNAUTHORIZED"}] = result.errors
    end

    test "a real team the caller is not a member of fails UNAUTHORIZED", ctx do
      outsider = user_fixture()

      result = RequireScope.call(resolution(outsider, %{team_id: ctx.team.id}), mode: :query)

      assert [%{code: "UNAUTHORIZED"}] = result.errors
    end

    test "mode defaults to :query when not given", ctx do
      result = RequireScope.call(resolution(nil, %{team_id: ctx.team.id}), [])

      assert [%{code: "UNAUTHENTICATED"}] = result.errors
    end
  end

  describe "mutation-mode failures" do
    test "an unauthenticated mutation resolves to the AuthorizationProblem", ctx do
      result =
        RequireScope.call(
          resolution(nil, %{input: %{team_id: ctx.team.id, client_mutation_id: "cmid-9"}}),
          mode: :mutation
        )

      assert result.state == :resolved
      assert result.errors == []

      assert %{
               __problem__: :authorization,
               code: "UNAUTHORIZED",
               client_mutation_id: "cmid-9"
             } = result.value
    end

    test "an unauthorized mutation resolves to the same problem shape", ctx do
      outsider = user_fixture()

      result =
        RequireScope.call(
          resolution(outsider, %{input: %{team_id: ctx.team.id}}),
          mode: :mutation
        )

      assert %{__problem__: :authorization, client_mutation_id: nil} = result.value
    end
  end
end
