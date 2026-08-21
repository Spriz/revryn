defmodule BillingCoreWeb.GraphQL.CatalogMutationsTest do
  @moduledoc """
  Catalog publication over GraphQL: product → plan → draft version with
  components → publish (BC-US-010/013/014).
  """

  use BillingCoreWeb.GraphQLCase, async: true

  setup %{conn: conn} do
    Map.put(register_actor(), :conn, conn)
  end

  test "publishes a plan version built entirely through the API", ctx do
    create_product = """
    mutation CreateProduct($input: CreateProductInput!) {
      createProduct(input: $input) {
        __typename
        ... on CreateProductSuccess { product { id code currentVersion } }
        ... on ValidationProblem { code fields { path message } }
      }
    }
    """

    {200, %{"data" => %{"createProduct" => product_payload}}} =
      gql(ctx.conn, create_product,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "code" => "platform",
            "name" => "Platform",
            "clientMutationId" => "cm-prod"
          }
        }
      )

    assert product_payload["__typename"] == "CreateProductSuccess"
    product_id = product_payload["product"]["id"]

    create_plan = """
    mutation CreatePlan($input: CreatePlanInput!) {
      createPlan(input: $input) {
        __typename
        ... on CreatePlanSuccess { plan { id code currentVersion } }
      }
    }
    """

    {200, %{"data" => %{"createPlan" => plan_payload}}} =
      gql(ctx.conn, create_plan,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "code" => "pro-monthly",
            "name" => "Pro Monthly",
            "clientMutationId" => "cm-plan"
          }
        }
      )

    assert plan_payload["__typename"] == "CreatePlanSuccess"
    plan_id = plan_payload["plan"]["id"]

    create_version = """
    mutation CreatePlanVersion($input: CreatePlanVersionInput!) {
      createPlanVersion(input: $input) {
        __typename
        ... on CreatePlanVersionSuccess {
          planVersion {
            id version status currency
            priceComponents { code pricingModel ordinal }
          }
        }
        ... on ValidationProblem { code message fields { path code message } }
      }
    }
    """

    {200, %{"data" => %{"createPlanVersion" => version_payload}}} =
      gql(ctx.conn, create_version,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "planId" => plan_id,
            "currency" => "DKK",
            "intervalUnit" => "MONTH",
            "intervalCount" => 1,
            "billingTiming" => "IN_ADVANCE",
            "components" => [
              %{
                "code" => "base-fee",
                "productId" => product_id,
                "pricingDefinition" => %{"fixedRecurring" => %{"unitPrice" => "499"}}
              }
            ],
            "clientMutationId" => "cm-version"
          }
        }
      )

    assert version_payload["__typename"] == "CreatePlanVersionSuccess"
    draft = version_payload["planVersion"]
    assert draft["status"] == "draft"

    assert [%{"code" => "base-fee", "pricingModel" => "fixed_recurring"}] =
             draft["priceComponents"]

    publish = """
    mutation PublishPlanVersion($input: PublishPlanVersionInput!) {
      publishPlanVersion(input: $input) {
        __typename
        ... on PublishPlanVersionSuccess {
          planVersion { id version status contentHash publishedAt }
        }
        ... on ValidationProblem { code }
      }
    }
    """

    {200, %{"data" => %{"publishPlanVersion" => published_payload}}} =
      gql(ctx.conn, publish,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "planVersionId" => draft["id"],
            "clientMutationId" => "cm-publish"
          }
        }
      )

    assert published_payload["__typename"] == "PublishPlanVersionSuccess"
    published = published_payload["planVersion"]
    assert published["status"] == "published"
    assert is_binary(published["contentHash"])

    # The published version is queryable through plan/planVersion.
    query = """
    query PlanAndVersion($teamId: ID!, $planId: ID!, $versionId: ID!) {
      plan(teamId: $teamId, id: $planId) { id currentVersion }
      planVersion(teamId: $teamId, id: $versionId) { id status version }
    }
    """

    {200, %{"data" => data}} =
      gql(ctx.conn, query,
        token: ctx.token,
        variables: %{
          "teamId" => ctx.team.id,
          "planId" => plan_id,
          "versionId" => draft["id"]
        }
      )

    assert data["plan"]["currentVersion"] == 1
    assert data["planVersion"]["status"] == "published"
  end

  test "an ambiguous pricing definition is a typed validation problem", ctx do
    product = product_fixture(ctx.scope)
    plan = plan_fixture(ctx.scope)

    create_version = """
    mutation CreatePlanVersion($input: CreatePlanVersionInput!) {
      createPlanVersion(input: $input) {
        __typename
        ... on ValidationProblem { code message }
      }
    }
    """

    {200, %{"data" => %{"createPlanVersion" => payload}}} =
      gql(ctx.conn, create_version,
        token: ctx.token,
        variables: %{
          "input" => %{
            "teamId" => ctx.team.id,
            "planId" => plan.id,
            "currency" => "DKK",
            "intervalUnit" => "MONTH",
            "intervalCount" => 1,
            "billingTiming" => "IN_ADVANCE",
            "components" => [
              %{
                "code" => "broken",
                "productId" => product.id,
                "pricingDefinition" => %{
                  "fixedRecurring" => %{"unitPrice" => "1"},
                  "oneTime" => %{"unitPrice" => "2"}
                }
              }
            ],
            "clientMutationId" => "cm-bad"
          }
        }
      )

    assert payload["__typename"] == "ValidationProblem"
    assert payload["code"] == "INVALID_PRICING_DEFINITION"
  end
end
