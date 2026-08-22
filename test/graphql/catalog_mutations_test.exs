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

  # Not covered on purpose: the resolver-level `Authz.can_read?` denial
  # branches (products/planVersion/publish) and the context `:unauthorized`
  # unwrap branch cannot fire over HTTP — scope resolution already requires
  # an active team membership, memberships carry at least one role, and
  # every canonical team role grants read access.

  describe "catalog queries" do
    test "product and discount resolve by ID; unknown IDs are NOT_FOUND", ctx do
      product = product_fixture(ctx.scope)
      discount = discount_fixture(ctx.scope)

      query = """
      query Catalog($teamId: ID!, $productId: ID!, $discountId: ID!) {
        product(teamId: $teamId, id: $productId) { id code status }
        discount(teamId: $teamId, id: $discountId) { id code status currentVersion }
      }
      """

      {200, %{"data" => data}} =
        gql(ctx.conn, query,
          token: ctx.token,
          variables: %{
            "teamId" => ctx.team.id,
            "productId" => product.id,
            "discountId" => discount.id
          }
        )

      assert data["product"]["id"] == product.id
      assert data["discount"]["id"] == discount.id

      {200, missing_body} =
        gql(ctx.conn, query,
          token: ctx.token,
          variables: %{
            "teamId" => ctx.team.id,
            "productId" => Ecto.UUID.generate(),
            "discountId" => Ecto.UUID.generate()
          }
        )

      assert missing_body["data"]["product"] == nil
      assert missing_body["data"]["discount"] == nil
      assert Enum.all?(missing_body["errors"], &(&1["code"] == "NOT_FOUND"))
    end

    test "an unknown planVersion is NOT_FOUND", ctx do
      query = """
      query PlanVersion($teamId: ID!, $id: ID!) {
        planVersion(teamId: $teamId, id: $id) { id }
      }
      """

      {200, body} =
        gql(ctx.conn, query,
          token: ctx.token,
          variables: %{"teamId" => ctx.team.id, "id" => Ecto.UUID.generate()}
        )

      assert body["data"]["planVersion"] == nil
      assert [%{"code" => "NOT_FOUND"} | _] = body["errors"]
    end

    test "products connection enforces page size and cursor validity", ctx do
      product_fixture(ctx.scope)

      query = """
      query Products($teamId: ID!, $first: Int, $after: String) {
        products(teamId: $teamId, first: $first, after: $after) {
          edges { node { id code } }
          pageInfo { hasNextPage }
        }
      }
      """

      {200, %{"data" => %{"products" => page}}} =
        gql(ctx.conn, query,
          token: ctx.token,
          variables: %{"teamId" => ctx.team.id, "first" => 10}
        )

      assert length(page["edges"]) == 1

      {200, oversized} =
        gql(ctx.conn, query,
          token: ctx.token,
          variables: %{"teamId" => ctx.team.id, "first" => 0}
        )

      assert [%{"code" => "INVALID_PAGE_SIZE"} | _] = oversized["errors"]

      {200, garbled} =
        gql(ctx.conn, query,
          token: ctx.token,
          variables: %{"teamId" => ctx.team.id, "first" => 5, "after" => "not-a-cursor"}
        )

      assert [%{"code" => "INVALID_CURSOR"} | _] = garbled["errors"]
    end
  end

  describe "catalog mutation problems" do
    @create_product """
    mutation CreateProduct($input: CreateProductInput!) {
      createProduct(input: $input) {
        __typename
        ... on CreateProductSuccess { product { id } }
        ... on ValidationProblem { code fields { path message } }
      }
    }
    """

    test "a duplicate product code is a typed ValidationProblem", ctx do
      product = product_fixture(ctx.scope)

      {200, %{"data" => %{"createProduct" => payload}}} =
        gql(ctx.conn, @create_product,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "code" => product.code,
              "name" => "Duplicate",
              "clientMutationId" => "dup-prod"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "VALIDATION_FAILED"
    end

    test "a duplicate plan code is a typed ValidationProblem", ctx do
      plan = plan_fixture(ctx.scope)

      mutation = """
      mutation CreatePlan($input: CreatePlanInput!) {
        createPlan(input: $input) {
          __typename
          ... on ValidationProblem { code }
        }
      }
      """

      {200, %{"data" => %{"createPlan" => payload}}} =
        gql(ctx.conn, mutation,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "code" => plan.code,
              "name" => "Duplicate",
              "clientMutationId" => "dup-plan"
            }
          }
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "VALIDATION_FAILED"
    end

    @create_version """
    mutation CreatePlanVersion($input: CreatePlanVersionInput!) {
      createPlanVersion(input: $input) {
        __typename
        ... on CreatePlanVersionSuccess {
          planVersion { id status priceComponents { code pricingModel ordinal } }
        }
        ... on ValidationProblem { code message fields { path code message } }
      }
    }
    """

    defp version_input(ctx, plan, components) do
      %{
        "teamId" => ctx.team.id,
        "planId" => plan.id,
        "currency" => "DKK",
        "intervalUnit" => "MONTH",
        "intervalCount" => 1,
        "billingTiming" => "IN_ADVANCE",
        "components" => components,
        "clientMutationId" => "cm-version"
      }
    end

    test "a draft version accepts every pricing model group (SPEC §9.6)", ctx do
      product = product_fixture(ctx.scope)
      plan = plan_fixture(ctx.scope)

      tiers = [
        %{"from" => "0", "to" => "100", "unitRate" => "2", "flatFeeMinor" => 500},
        %{"from" => "100", "unitRate" => "1"}
      ]

      components = [
        %{
          "code" => "one-off",
          "productId" => product.id,
          "pricingDefinition" => %{"oneTime" => %{"unitPrice" => "150"}}
        },
        %{
          "code" => "metered",
          "productId" => product.id,
          "metricCode" => "api_calls",
          "aggregation" => "sum",
          "pricingDefinition" => %{"standardMetered" => %{"unitRate" => "0.05"}}
        },
        %{
          "code" => "volume",
          "productId" => product.id,
          "metricCode" => "api_calls",
          "aggregation" => "sum",
          "pricingDefinition" => %{"volumeTier" => %{"tiers" => tiers}}
        },
        %{
          "code" => "graduated",
          "productId" => product.id,
          "metricCode" => "api_calls",
          "aggregation" => "sum",
          "pricingDefinition" => %{"graduatedTier" => %{"tiers" => tiers}}
        },
        %{
          "code" => "packaged",
          "productId" => product.id,
          "metricCode" => "api_calls",
          "aggregation" => "sum",
          "pricingDefinition" => %{
            "package" => %{"packageSize" => "1000", "packagePrice" => "9"}
          }
        },
        %{
          "code" => "committed",
          "productId" => product.id,
          "pricingDefinition" => %{
            "minimumCommit" => %{
              "minimumAmountMinor" => 10_000,
              "inner" => %{"fixedRecurring" => %{"unitPrice" => "80"}}
            }
          }
        }
      ]

      {200, %{"data" => %{"createPlanVersion" => payload}}} =
        gql(ctx.conn, @create_version,
          token: ctx.token,
          variables: %{"input" => version_input(ctx, plan, components)}
        )

      assert payload["__typename"] == "CreatePlanVersionSuccess"

      models =
        payload["planVersion"]["priceComponents"]
        |> Enum.map(&{&1["code"], &1["pricingModel"]})
        |> Map.new()

      assert models == %{
               "one-off" => "one_time",
               "metered" => "standard_metered",
               "volume" => "volume_tier",
               "graduated" => "graduated_tier",
               "packaged" => "package",
               "committed" => "minimum_commit"
             }
    end

    test "a minimum commit with an ambiguous inner definition is rejected", ctx do
      product = product_fixture(ctx.scope)
      plan = plan_fixture(ctx.scope)

      components = [
        %{
          "code" => "committed",
          "productId" => product.id,
          "pricingDefinition" => %{
            "minimumCommit" => %{
              "minimumAmountMinor" => 10_000,
              "inner" => %{
                "fixedRecurring" => %{"unitPrice" => "80"},
                "oneTime" => %{"unitPrice" => "80"}
              }
            }
          }
        }
      ]

      {200, %{"data" => %{"createPlanVersion" => payload}}} =
        gql(ctx.conn, @create_version,
          token: ctx.token,
          variables: %{"input" => version_input(ctx, plan, components)}
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "INVALID_PRICING_DEFINITION"
    end

    test "domain tier validation failures roll the whole version back", ctx do
      product = product_fixture(ctx.scope)
      plan = plan_fixture(ctx.scope)

      # Non-contiguous tiers pass GraphQL shape validation but fail the
      # domain pricing schema inside the creation transaction.
      components = [
        %{
          "code" => "broken-tiers",
          "productId" => product.id,
          "metricCode" => "api_calls",
          "aggregation" => "sum",
          "pricingDefinition" => %{
            "volumeTier" => %{
              "tiers" => [
                %{"from" => "0", "to" => "10", "unitRate" => "2"},
                %{"from" => "20", "unitRate" => "1"}
              ]
            }
          }
        }
      ]

      {200, %{"data" => %{"createPlanVersion" => payload}}} =
        gql(ctx.conn, @create_version,
          token: ctx.token,
          variables: %{"input" => version_input(ctx, plan, components)}
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "INVALID_PRICING_DEFINITION"
      assert Enum.any?(payload["fields"], &(&1["path"] == ["components", "broken-tiers"]))
    end

    test "a component referencing an unknown product rolls back with a typed problem", ctx do
      plan = plan_fixture(ctx.scope)

      components = [
        %{
          "code" => "orphan",
          "productId" => Ecto.UUID.generate(),
          "pricingDefinition" => %{"fixedRecurring" => %{"unitPrice" => "10"}}
        }
      ]

      {200, %{"data" => %{"createPlanVersion" => payload}}} =
        gql(ctx.conn, @create_version,
          token: ctx.token,
          variables: %{"input" => version_input(ctx, plan, components)}
        )

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "PRODUCT_NOT_FOUND"
    end

    test "an unknown plan is a typed NOT_FOUND problem", ctx do
      product = product_fixture(ctx.scope)

      components = [
        %{
          "code" => "base",
          "productId" => product.id,
          "pricingDefinition" => %{"fixedRecurring" => %{"unitPrice" => "10"}}
        }
      ]

      input = version_input(ctx, %{id: Ecto.UUID.generate()}, components)

      {200, %{"data" => %{"createPlanVersion" => payload}}} =
        gql(ctx.conn, @create_version, token: ctx.token, variables: %{"input" => input})

      assert payload["__typename"] == "ValidationProblem"
      assert payload["code"] == "NOT_FOUND"
    end

    @publish """
    mutation PublishPlanVersion($input: PublishPlanVersionInput!) {
      publishPlanVersion(input: $input) {
        __typename
        ... on PublishPlanVersionSuccess { planVersion { id status } }
        ... on ValidationProblem { code }
      }
    }
    """

    test "publishing an unknown version and republishing are typed problems", ctx do
      {200, %{"data" => %{"publishPlanVersion" => missing}}} =
        gql(ctx.conn, @publish,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "planVersionId" => Ecto.UUID.generate(),
              "clientMutationId" => "pub-missing"
            }
          }
        )

      assert missing["__typename"] == "ValidationProblem"
      assert missing["code"] == "NOT_FOUND"

      # Published versions are immutable: publishing again is NOT_DRAFT.
      published = published_plan_version_fixture(ctx.scope)

      {200, %{"data" => %{"publishPlanVersion" => republished}}} =
        gql(ctx.conn, @publish,
          token: ctx.token,
          variables: %{
            "input" => %{
              "teamId" => ctx.team.id,
              "planVersionId" => published.id,
              "clientMutationId" => "pub-again"
            }
          }
        )

      assert republished["__typename"] == "ValidationProblem"
      assert republished["code"] == "NOT_DRAFT"
    end
  end
end
