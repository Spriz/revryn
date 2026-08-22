from datetime import timedelta

from django.test import TestCase
from django.utils import timezone

from accounts.models import Membership, Organization, User
from automation.models import AutomationRun, Rule
from billing_seam.seam import INCLUDED_AUTOMATION_RUNS, LocalFixtureProvider, format_minor
from work.models import Board, Column, Project


class SeamMathTests(TestCase):
    """Pure fixture math — integer minor units, never floats."""

    def setUp(self):
        self.provider = LocalFixtureProvider()

    def test_seat_tiers_select_by_active_members(self):
        self.assertEqual(self.provider.seat_tier(3), ("Studio", 4_900))
        self.assertEqual(self.provider.seat_tier(5), ("Studio", 4_900))
        self.assertEqual(self.provider.seat_tier(6), ("Agency", 3_900))
        self.assertEqual(self.provider.seat_tier(21), ("Scale", 2_900))

    def test_graduated_overage_prices_each_band(self):
        self.assertEqual(self.provider.overage_cost_minor(0), 0)
        # 100 runs inside the first band at 50/run
        self.assertEqual(self.provider.overage_cost_minor(100), 5_000)
        # 300@50 + 200@35
        self.assertEqual(self.provider.overage_cost_minor(500), 300 * 50 + 200 * 35)
        # 300@50 + 500@35 + 100@20 — the unbounded tail
        self.assertEqual(
            self.provider.overage_cost_minor(900), 300 * 50 + 500 * 35 + 100 * 20
        )

    def test_format_minor_never_uses_floats(self):
        self.assertEqual(format_minor(1_234_501), "12,345.01 DKK")


class SeamSummaryTests(TestCase):
    def setUp(self):
        self.organization = Organization.objects.create(name="Seam", slug="seam")
        for n in range(6):
            user = User.objects.create_user(
                email=f"m{n}@example.com", password="sikkerhed123"
            )
            Membership.objects.create(organization=self.organization, user=user)
        project = Project.objects.create(organization=self.organization, name="P")
        board = Board.objects.create(project=project, name="B")
        column = Column.objects.create(board=board, name="C")
        self.rule = Rule.objects.create(
            project=project,
            name="R",
            trigger_column=column,
            action=Rule.NOTIFY_CREATOR,
        )

    def _run(self, status=AutomationRun.SUCCEEDED, when=None):
        AutomationRun.objects.create(
            rule=self.rule,
            organization=self.organization,
            status=status,
            ran_at=when or timezone.now(),
        )

    def test_summary_counts_only_this_months_successful_runs(self):
        for _ in range(INCLUDED_AUTOMATION_RUNS + 10):
            self._run()
        self._run(status=AutomationRun.SKIPPED)
        self._run(when=timezone.now() - timedelta(days=45))

        summary = LocalFixtureProvider().summarize(self.organization)
        self.assertEqual(summary.active_members, 6)
        self.assertEqual(summary.seat_tier_name, "Agency")
        self.assertEqual(summary.automation_runs, INCLUDED_AUTOMATION_RUNS + 10)
        self.assertEqual(summary.overage_runs, 10)
        self.assertEqual(summary.overage_total_minor, 10 * 50)
        self.assertEqual(summary.seat_total_minor, 6 * 3_900)
        self.assertEqual(summary.total_minor, 6 * 3_900 + 500)
