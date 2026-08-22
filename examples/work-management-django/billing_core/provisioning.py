"""Idempotent provisioning of one Driftbord organization into Billing
Core through the public GraphQL contract only (BC-US-151 final milestone).

Product/plan are shared per team (stable codes); customer, contract, and
subscription are per organization. Quantity = active members; automation
runs flow as usage events keyed by AutomationRun id (exactly-once by
external event id).
"""

from datetime import date

from .client import Client
from .models import BillingCoreLink

PRODUCT_CODE = "driftbord-seat"
PLAN_CODE = "driftbord"
SEAT_PRICE_MAJOR = "39.00"
METRIC_CODE = "automation_runs"

_CREATE_PRODUCT = """
mutation DriftbordProduct($input: CreateProductInput!) {
  createProduct(input: $input) {
    __typename
    ... on CreateProductSuccess { product { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
  }
}
"""

_CREATE_PLAN = """
mutation DriftbordPlan($input: CreatePlanInput!) {
  createPlan(input: $input) {
    __typename
    ... on CreatePlanSuccess { plan { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
  }
}
"""

_CREATE_PLAN_VERSION = """
mutation DriftbordPlanVersion($input: CreatePlanVersionInput!) {
  createPlanVersion(input: $input) {
    __typename
    ... on CreatePlanVersionSuccess { planVersion { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
  }
}
"""

_PUBLISH = """
mutation DriftbordPublish($input: PublishPlanVersionInput!) {
  publishPlanVersion(input: $input) {
    __typename
    ... on PublishPlanVersionSuccess { planVersion { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
  }
}
"""

_UPSERT_CUSTOMER = """
mutation DriftbordCustomer($input: UpsertCustomerInput!) {
  upsertCustomer(input: $input) {
    __typename
    ... on UpsertCustomerSuccess { customer { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
    ... on VersionConflict { expectedVersion actualVersion }
  }
}
"""

_CREATE_CONTRACT = """
mutation DriftbordContract($input: CreateContractInput!) {
  createContract(input: $input) {
    __typename
    ... on CreateContractSuccess { contract { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
  }
}
"""

_CREATE_SUBSCRIPTION = """
mutation DriftbordSubscription($input: CreateSubscriptionInput!) {
  createSubscription(input: $input) {
    __typename
    ... on CreateSubscriptionSuccess { subscription { id } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
    ... on IdempotencyConflict { code message }
  }
}
"""

_CHANGE_SUBSCRIPTION = """
mutation DriftbordChange($input: ChangeSubscriptionInput!) {
  changeSubscription(input: $input) {
    __typename
    ... on ChangeSubscriptionSuccess { subscription { id currentVersion } }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
    ... on IdempotencyConflict { code message }
  }
}
"""

_INGEST = """
mutation DriftbordUsage($input: IngestUsageEventInput!) {
  ingestUsageEvent(input: $input) {
    __typename
    ... on IngestUsageEventSuccess { outcome { status } duplicate }
    ... on UsageEventConflict { code message }
    ... on ValidationProblem { code message }
    ... on AuthorizationProblem { code message }
  }
}
"""

_PLANS = """
query DriftbordPlans($teamId: ID!, $first: Int) {
  products(teamId: $teamId, first: $first) { edges { node { id code } } }
}
"""


def _cmid(tag):
    return f"driftbord:{tag}"


def ensure_plan_version(client):
    """Team-level product/plan/version, created once, found thereafter."""
    products = client.execute(_PLANS, {"teamId": client.team_id, "first": 100})
    product_id = next(
        (edge["node"]["id"] for edge in products["products"]["edges"]
         if edge["node"]["code"] == PRODUCT_CODE),
        None,
    )
    if product_id is None:
        product = client.mutate("createProduct", _CREATE_PRODUCT, {"input": {
            "teamId": client.team_id, "code": PRODUCT_CODE,
            "name": "Driftbord seat", "recognitionMode": "OVER_TIME",
            "servicePeriodSource": "billing_period",
            "clientMutationId": _cmid("product"),
        }})
        product_id = product["product"]["id"]

        plan = client.mutate("createPlan", _CREATE_PLAN, {"input": {
            "teamId": client.team_id, "code": PLAN_CODE,
            "name": "Driftbord", "clientMutationId": _cmid("plan"),
        }})
        version = client.mutate("createPlanVersion", _CREATE_PLAN_VERSION, {"input": {
            "teamId": client.team_id, "planId": plan["plan"]["id"],
            "currency": "DKK", "intervalUnit": "MONTH", "intervalCount": 1,
            "billingTiming": "IN_ADVANCE",
            "components": [{
                "code": "seat", "productId": product_id,
                "pricingDefinition": {"fixedRecurring": {"unitPrice": SEAT_PRICE_MAJOR}},
                "prorationPolicy": "prorate", "ordinal": 1,
            }],
            "clientMutationId": _cmid("version"),
        }})
        version_id = version["planVersion"]["id"]
        client.mutate("publishPlanVersion", _PUBLISH, {"input": {
            "teamId": client.team_id, "planVersionId": version_id,
            "clientMutationId": _cmid("publish"),
        }})
        return version_id

    # Product exists → the published version was created with it.
    from .models import BillingCoreLink

    link = BillingCoreLink.objects.exclude(plan_version_id="").first()
    if link:
        return link.plan_version_id
    raise RuntimeError("product exists but no recorded plan version; provision from scratch")


def ensure_provisioned(organization, client=None):
    """Creates (once) the Billing Core customer/contract/subscription for
    an organization and records the identities locally."""
    link = getattr(organization, "billing_core_link", None)
    if link:
        return link

    client = client or Client()
    plan_version_id = ensure_plan_version(client)

    customer = client.mutate("upsertCustomer", _UPSERT_CUSTOMER, {"input": {
        "teamId": client.team_id, "externalId": f"driftbord-{organization.slug}",
        "legalName": organization.name, "country": "DK",
        "email": f"billing+{organization.slug}@driftbord.example",
        "idempotencyKey": f"driftbord-customer-{organization.slug}",
        "clientMutationId": _cmid(f"customer-{organization.slug}"),
    }})

    contract = client.mutate("createContract", _CREATE_CONTRACT, {"input": {
        "teamId": client.team_id, "customerId": customer["customer"]["id"],
        "currency": "DKK", "startDate": date.today().isoformat(),
        "externalReference": f"driftbord-{organization.slug}",
        "clientMutationId": _cmid(f"contract-{organization.slug}"),
    }})

    subscription = client.mutate("createSubscription", _CREATE_SUBSCRIPTION, {"input": {
        "teamId": client.team_id, "contractId": contract["contract"]["id"],
        "externalId": f"driftbord-{organization.slug}",
        "planVersionId": plan_version_id, "startsOn": date.today().isoformat(),
        "quantity": str(organization.active_member_count()),
        "idempotencyKey": f"driftbord-sub-{organization.slug}",
        "clientMutationId": _cmid(f"subscription-{organization.slug}"),
    }})

    return BillingCoreLink.objects.create(
        organization=organization,
        customer_id=customer["customer"]["id"],
        contract_id=contract["contract"]["id"],
        subscription_id=subscription["subscription"]["id"],
        plan_version_id=plan_version_id,
    )


def sync_seats(organization, client=None):
    """Membership changed → subscription quantity follows (idempotent by
    quantity-stamped key)."""
    client = client or Client()
    link = ensure_provisioned(organization, client)
    quantity = organization.active_member_count()
    client.mutate("changeSubscription", _CHANGE_SUBSCRIPTION, {"input": {
        "teamId": client.team_id, "subscriptionId": link.subscription_id,
        "quantity": str(quantity),
        "idempotencyKey": f"driftbord-seats-{organization.slug}-{quantity}",
        "clientMutationId": _cmid(f"seats-{organization.slug}"),
    }})


def push_automation_run(run, client=None):
    """One AutomationRun → one usage event, exactly once by run id."""
    client = client or Client()
    link = ensure_provisioned(run.organization, client)
    return client.mutate("ingestUsageEvent", _INGEST, {"input": {
        "teamId": client.team_id, "externalEventId": f"driftbord-run-{run.id}",
        "subscriptionId": link.subscription_id, "metricCode": METRIC_CODE,
        "occurredAt": run.ran_at.isoformat(), "value": "1",
        "properties": {"rule": run.rule.name, "status": run.status},
        "clientMutationId": _cmid(f"run-{run.id}"),
    }})
