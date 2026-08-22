"""The Billing Core-backed seam provider (BC-US-151 final milestone).

`summarize` answers the same question the local fixtures answer, but from
a live Billing Core invoice preview — and carries the preview lines plus
fingerprint so the UI can show exactly which upstream invoice lines the
totals trace to.
"""

from datetime import date

from billing_seam.seam import UsageSummary

from .client import Client
from .provisioning import ensure_provisioned

_PREVIEW = """
query DriftbordPreview($teamId: ID!, $subscriptionId: ID!, $asOf: Date!) {
  invoicePreview(teamId: $teamId, subscriptionId: $subscriptionId, asOf: $asOf) {
    netAmountMinor
    fingerprint
    lines { lineKey description quantity amountMinor }
  }
}
"""


class BillingCoreProvider:
    def __init__(self, client=None):
        self.client = client or Client()

    def summarize(self, organization, period_start=None):
        from automation.models import AutomationRun

        link = ensure_provisioned(organization, self.client)
        preview = self.client.execute(_PREVIEW, {
            "teamId": self.client.team_id,
            "subscriptionId": link.subscription_id,
            "asOf": date.today().isoformat(),
        })["invoicePreview"]

        period_start = period_start or date.today().replace(day=1)
        runs = AutomationRun.objects.filter(
            organization=organization,
            status=AutomationRun.SUCCEEDED,
            ran_at__date__gte=period_start,
        ).count()

        active = organization.active_member_count()
        seat_total = sum(line["amountMinor"] for line in preview["lines"])

        summary = UsageSummary(
            active_members=active,
            seat_tier_name="Billing Core",
            seat_price_minor=seat_total // max(active, 1),
            seat_total_minor=seat_total,
            automation_runs=runs,
            included_runs=0,
            overage_runs=0,
            overage_total_minor=0,
        )
        # Traceability for the UI (BC-US-151 acceptance).
        summary.preview_lines = preview["lines"]
        summary.preview_fingerprint = preview["fingerprint"]
        summary.net_amount_minor = preview["netAmountMinor"]
        return summary
