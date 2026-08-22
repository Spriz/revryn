# Idempotent provisioning of one CRM organization into Billing Core
# through the public GraphQL contract only (BC-US-150 final milestone).
# Subscription quantity = billable seats (the CRM's decrease-timing rule
# stays authoritative locally and flows through as the quantity).
module BillingCore
  module Provisioning
    PRODUCT_CODE = "kystvej-seat"
    PLAN_CODE = "kystvej"
    SEAT_PRICE_MAJOR = "99.00"

    module_function

    def cmid(tag) = "kystvej:#{tag}"

    def ensure_plan_version(client)
      products = client.execute(
        "query($t: ID!, $f: Int){ products(teamId: $t, first: $f){ edges { node { id code } } } }",
        { "t" => client.team_id, "f" => 100 }
      )
      product = products.dig("products", "edges").find { |edge| edge.dig("node", "code") == PRODUCT_CODE }
      if product
        link = BillingCoreLink.where.not(plan_version_id: "").first
        return link.plan_version_id if link

        raise Error, "product exists but no recorded plan version"
      end

      created = client.mutate("createProduct", <<~GQL, { "input" => {
        mutation($input: CreateProductInput!) {
          createProduct(input: $input) {
            __typename
            ... on CreateProductSuccess { product { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "code" => PRODUCT_CODE, "name" => "Kystvej seat",
        "recognitionMode" => "OVER_TIME", "servicePeriodSource" => "billing_period",
        "clientMutationId" => cmid("product") } })

      plan = client.mutate("createPlan", <<~GQL, { "input" => {
        mutation($input: CreatePlanInput!) {
          createPlan(input: $input) {
            __typename
            ... on CreatePlanSuccess { plan { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "code" => PLAN_CODE, "name" => "Kystvej CRM",
        "clientMutationId" => cmid("plan") } })

      version = client.mutate("createPlanVersion", <<~GQL, { "input" => {
        mutation($input: CreatePlanVersionInput!) {
          createPlanVersion(input: $input) {
            __typename
            ... on CreatePlanVersionSuccess { planVersion { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "planId" => plan.dig("plan", "id"),
        "currency" => "DKK", "intervalUnit" => "MONTH", "intervalCount" => 1,
        "billingTiming" => "IN_ADVANCE",
        "components" => [
          {
            "code" => "seat", "productId" => created.dig("product", "id"),
            "pricingDefinition" => { "fixedRecurring" => { "unitPrice" => SEAT_PRICE_MAJOR } },
            "prorationPolicy" => "prorate", "ordinal" => 1
          },
          {
            # Flat base plan: minimum-commit over a zero-rate inner model
            # (SPEC 10.6) — quantity-independent by construction.
            "code" => "base", "productId" => created.dig("product", "id"),
            "pricingDefinition" => {
              "minimumCommit" => {
                "minimumAmountMinor" => BillingSeam::BASE_PLAN_ORE,
                "inner" => { "fixedRecurring" => { "unitPrice" => "0" } }
              }
            },
            "prorationPolicy" => "full_period", "ordinal" => 2
          }
        ],
        "clientMutationId" => cmid("version") } })
      version_id = version.dig("planVersion", "id")

      client.mutate("publishPlanVersion", <<~GQL, { "input" => {
        mutation($input: PublishPlanVersionInput!) {
          publishPlanVersion(input: $input) {
            __typename
            ... on PublishPlanVersionSuccess { planVersion { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "planVersionId" => version_id,
        "clientMutationId" => cmid("publish") } })

      version_id
    end

    def ensure_provisioned(organization, client = Client.new)
      link = BillingCoreLink.find_by(organization: organization)
      return link if link

      plan_version_id = ensure_plan_version(client)

      customer = client.mutate("upsertCustomer", <<~GQL, { "input" => {
        mutation($input: UpsertCustomerInput!) {
          upsertCustomer(input: $input) {
            __typename
            ... on UpsertCustomerSuccess { customer { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
            ... on VersionConflict { expectedVersion actualVersion }
          }
        }
      GQL
        "teamId" => client.team_id, "externalId" => "kystvej-#{organization.slug}",
        "legalName" => organization.name, "country" => "DK",
        "email" => "billing+#{organization.slug}@kystvej.example",
        "idempotencyKey" => "kystvej-customer-#{organization.slug}",
        "clientMutationId" => cmid("customer-#{organization.slug}") } })

      contract = client.mutate("createContract", <<~GQL, { "input" => {
        mutation($input: CreateContractInput!) {
          createContract(input: $input) {
            __typename
            ... on CreateContractSuccess { contract { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "customerId" => customer.dig("customer", "id"),
        "currency" => "DKK", "startDate" => Date.today.iso8601,
        "externalReference" => "kystvej-#{organization.slug}",
        "clientMutationId" => cmid("contract-#{organization.slug}") } })

      subscription = client.mutate("createSubscription", <<~GQL, { "input" => {
        mutation($input: CreateSubscriptionInput!) {
          createSubscription(input: $input) {
            __typename
            ... on CreateSubscriptionSuccess { subscription { id } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
            ... on IdempotencyConflict { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "contractId" => contract.dig("contract", "id"),
        "externalId" => "kystvej-#{organization.slug}",
        "planVersionId" => plan_version_id, "startsOn" => Date.today.iso8601,
        "quantity" => organization.billable_seats.to_s,
        "idempotencyKey" => "kystvej-sub-#{organization.slug}",
        "clientMutationId" => cmid("subscription-#{organization.slug}") } })

      BillingCoreLink.create!(
        organization: organization,
        customer_ref: customer.dig("customer", "id"),
        contract_ref: contract.dig("contract", "id"),
        subscription_ref: subscription.dig("subscription", "id"),
        plan_version_ref: plan_version_id
      )
    end

    def sync_seats(organization, client = Client.new)
      link = ensure_provisioned(organization, client)
      quantity = organization.billable_seats
      client.mutate("changeSubscription", <<~GQL, { "input" => {
        mutation($input: ChangeSubscriptionInput!) {
          changeSubscription(input: $input) {
            __typename
            ... on ChangeSubscriptionSuccess { subscription { id currentVersion } }
            ... on ValidationProblem { code message }
            ... on AuthorizationProblem { code message }
            ... on IdempotencyConflict { code message }
          }
        }
      GQL
        "teamId" => client.team_id, "subscriptionId" => link.subscription_ref,
        "quantity" => quantity.to_s,
        "idempotencyKey" => "kystvej-seats-#{organization.slug}-#{quantity}",
        "clientMutationId" => cmid("seats-#{organization.slug}") } })
    end
  end
end
