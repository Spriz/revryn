"""The application-local billing seam (BC-US-151, INV-030/031).

Every plan/entitlement question the product asks goes through this module
and nothing else. In standalone mode the answers come from the local
fixtures below; the future Billing Core integration replaces the provider
behind `get_provider()` with a GraphQL-backed one WITHOUT touching any
caller — and the standalone provider (and its tests) remain forever.

Billing model (SPEC): tiered active-member pricing plus metered automation
runs with a monthly included quantity and graduated overage tiers.
Amounts are integer minor units (DKK øre) — never floats.
"""

from dataclasses import dataclass
from datetime import date


# --- Local showcase fixtures -------------------------------------------------

SEAT_TIERS = [
    # (max active members inclusive, price per member per month, tier name)
    (5, 4_900, "Studio"),
    (20, 3_900, "Agency"),
    (None, 2_900, "Scale"),
]

INCLUDED_AUTOMATION_RUNS = 200

OVERAGE_TIERS = [
    # (runs in this graduated band, price per run) — None = unbounded tail
    (300, 50),
    (500, 35),
    (None, 20),
]

CURRENCY = "DKK"


@dataclass
class UsageSummary:
    active_members: int
    seat_tier_name: str
    seat_price_minor: int
    seat_total_minor: int
    automation_runs: int
    included_runs: int
    overage_runs: int
    overage_total_minor: int
    currency: str = CURRENCY

    @property
    def total_minor(self):
        return self.seat_total_minor + self.overage_total_minor


class LocalFixtureProvider:
    """Standalone answers from the fixtures above (no network, ever)."""

    def seat_tier(self, active_members):
        for cap, price, name in SEAT_TIERS:
            if cap is None or active_members <= cap:
                return name, price
        raise AssertionError("unreachable: last tier is unbounded")

    def overage_cost_minor(self, overage_runs):
        """Graduated: each band prices only the runs inside it."""
        remaining, total = overage_runs, 0
        for band, price in OVERAGE_TIERS:
            if remaining <= 0:
                break
            in_band = remaining if band is None else min(remaining, band)
            total += in_band * price
            remaining -= in_band
        return total

    def summarize(self, organization, period_start=None):
        from automation.models import AutomationRun
        from accounts.models import Membership

        period_start = period_start or date.today().replace(day=1)
        active = organization.memberships.filter(status=Membership.ACTIVE).count()
        tier_name, seat_price = self.seat_tier(active)

        runs = AutomationRun.objects.filter(
            organization=organization,
            status=AutomationRun.SUCCEEDED,
            ran_at__date__gte=period_start,
        ).count()
        overage = max(runs - INCLUDED_AUTOMATION_RUNS, 0)

        return UsageSummary(
            active_members=active,
            seat_tier_name=tier_name,
            seat_price_minor=seat_price,
            seat_total_minor=active * seat_price,
            automation_runs=runs,
            included_runs=INCLUDED_AUTOMATION_RUNS,
            overage_runs=overage,
            overage_total_minor=self.overage_cost_minor(overage),
        )


_provider = LocalFixtureProvider()


def get_provider():
    """The single seam callers use; integrated mode swaps the provider
    for the Billing Core-backed one (BC-US-151 final milestone) without
    touching any caller."""
    from billing_core import integration

    if integration.enabled():
        from billing_core.provider import BillingCoreProvider

        return BillingCoreProvider()
    return _provider


def format_minor(amount_minor, currency=CURRENCY):
    major, minor = divmod(amount_minor, 100)
    return f"{major:,}.{minor:02d} {currency}"
