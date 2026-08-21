defmodule BillingCoreWeb.GraphQL.SchemaSdlTest do
  @moduledoc """
  The checked-in SDL artifact must match the compiled schema exactly
  (SPEC §14.1: deterministic SDL export, diffed in CI; §14.13).
  """

  use ExUnit.Case, async: true

  @sdl_path Path.expand("../../schema/billing_core.graphql", __DIR__)

  test "schema/billing_core.graphql matches the compiled schema" do
    generated = Absinthe.Schema.to_sdl(BillingCoreWeb.GraphQL.Schema)
    checked_in = File.read!(@sdl_path)

    assert checked_in == generated, """
    The checked-in SDL artifact is stale.

    The GraphQL schema changed but schema/billing_core.graphql was not
    regenerated. Review the diff for compatibility (SPEC §14.13: removals
    and narrowing changes need an approved deprecation path), then run:

        mix run --no-start -e 'File.write!("schema/billing_core.graphql", \
    Absinthe.Schema.to_sdl(BillingCoreWeb.GraphQL.Schema))'

    and commit the regenerated file together with the schema change.
    """
  end
end
