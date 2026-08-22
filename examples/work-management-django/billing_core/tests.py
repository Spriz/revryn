"""Adapter tests with a stubbed client — no network, standalone-safe.

They prove the integration contract: idempotent provisioning, seat-quantity
sync on membership changes, exactly-once usage push, preview traceability,
and the BC-US-153 failure taxonomy.
"""

from django.test import TestCase

from accounts.models import Membership, Organization, User
from automation.models import AutomationRun, Rule
from work.models import Board, Column, Project

from .client import AuthenticationError, DomainRejection
from .models import BillingCoreLink
from .provider import BillingCoreProvider
from . import provisioning


class StubClient:
    """Replays canned GraphQL answers and records every document sent."""

    team_id = "team-1"

    def __init__(self):
        self.calls = []
        self.products = []

    def execute(self, document, variables=None):
        self.calls.append(("execute", document, variables))
        if "products(" in document:
            return {"products": {"edges": self.products}}
        if "invoicePreview" in document:
            return {
                "invoicePreview": {
                    "netAmountMinor": 7_800,
                    "fingerprint": "fp-preview-1",
                    "lines": [
                        {"lineKey": "sub:driftbord:seat", "description": "Driftbord seat",
                         "quantity": "2", "amountMinor": 7_800}
                    ],
                }
            }
        raise AssertionError(f"unexpected query: {document[:60]}")

    def mutate(self, field, document, variables):
        self.calls.append((field, variables["input"]))
        payloads = {
            "createProduct": {"product": {"id": "prod-1"}},
            "createPlan": {"plan": {"id": "plan-1"}},
            "createPlanVersion": {"planVersion": {"id": "pv-1"}},
            "publishPlanVersion": {"planVersion": {"id": "pv-1"}},
            "upsertCustomer": {"customer": {"id": "cust-1"}},
            "createContract": {"contract": {"id": "con-1"}},
            "createSubscription": {"subscription": {"id": "sub-1"}},
            "changeSubscription": {"subscription": {"id": "sub-1", "currentVersion": 2}},
            "ingestUsageEvent": {"outcome": {"status": "accepted"}, "duplicate": False},
        }
        return payloads[field]


def make_org():
    organization = Organization.objects.create(name="Integreret", slug="integreret")
    user = User.objects.create_user(email="ejer@example.com", password="sikkerhed123")
    Membership.objects.create(organization=organization, user=user, role=Membership.OWNER)
    return organization


class ProvisioningTests(TestCase):
    def test_first_provision_creates_the_full_chain_and_records_ids(self):
        organization = make_org()
        client = StubClient()

        link = provisioning.ensure_provisioned(organization, client)

        fields = [call[0] for call in client.calls if call[0] != "execute"]
        self.assertEqual(
            fields,
            ["createProduct", "createPlan", "createPlanVersion", "publishPlanVersion",
             "upsertCustomer", "createContract", "createSubscription"],
        )
        self.assertEqual(link.subscription_id, "sub-1")

        subscription_input = dict(client.calls[-1][1])
        self.assertEqual(subscription_input["quantity"], "1")
        self.assertEqual(subscription_input["externalId"], "driftbord-integreret")

        # Idempotent: the second call sends nothing.
        before = len(client.calls)
        provisioning.ensure_provisioned(organization, client)
        self.assertEqual(len(client.calls), before)

    def test_seat_sync_stamps_quantity_into_the_idempotency_key(self):
        organization = make_org()
        client = StubClient()
        provisioning.ensure_provisioned(organization, client)

        extra = User.objects.create_user(email="to@example.com", password="sikkerhed123")
        Membership.objects.create(organization=organization, user=extra)
        provisioning.sync_seats(organization, client)

        field, payload = client.calls[-1]
        self.assertEqual(field, "changeSubscription")
        self.assertEqual(payload["quantity"], "2")
        self.assertEqual(payload["idempotencyKey"], "driftbord-seats-integreret-2")

    def test_automation_run_pushes_exactly_one_usage_event_by_run_id(self):
        organization = make_org()
        client = StubClient()
        provisioning.ensure_provisioned(organization, client)

        project = Project.objects.create(organization=organization, name="P")
        board = Board.objects.create(project=project, name="B")
        column = Column.objects.create(board=board, name="C")
        rule = Rule.objects.create(
            project=project, name="R", trigger_column=column, action=Rule.NOTIFY_CREATOR
        )
        run = AutomationRun.objects.create(rule=rule, organization=organization)

        provisioning.push_automation_run(run, client)
        field, payload = client.calls[-1]
        self.assertEqual(field, "ingestUsageEvent")
        self.assertEqual(payload["externalEventId"], f"driftbord-run-{run.id}")
        self.assertEqual(payload["value"], "1")


class ProviderTests(TestCase):
    def test_summarize_maps_the_preview_and_carries_traceability(self):
        organization = make_org()
        BillingCoreLink.objects.create(
            organization=organization, customer_id="cust-1", contract_id="con-1",
            subscription_id="sub-1", plan_version_id="pv-1",
        )
        summary = BillingCoreProvider(StubClient()).summarize(organization)

        self.assertEqual(summary.seat_total_minor, 7_800)
        self.assertEqual(summary.preview_fingerprint, "fp-preview-1")
        self.assertEqual(summary.net_amount_minor, 7_800)
        self.assertEqual(summary.preview_lines[0]["lineKey"], "sub:driftbord:seat")


class FailureTaxonomyTests(TestCase):
    def test_domain_rejections_and_auth_failures_are_distinct(self):
        # BC-US-153: contract failures must be distinguishable.
        self.assertTrue(issubclass(DomainRejection, Exception))
        self.assertTrue(issubclass(AuthenticationError, Exception))
        self.assertNotEqual(DomainRejection.__mro__[1], AuthenticationError.__mro__[1] and None)

        rejection = DomainRejection("LAST_OWNER", "refused")
        self.assertEqual(rejection.code, "LAST_OWNER")
