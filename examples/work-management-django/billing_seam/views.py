from django.contrib.auth.decorators import login_required
from django.http import HttpResponseForbidden
from django.shortcuts import get_object_or_404, render

from accounts.models import Membership, Organization

from .seam import format_minor, get_provider


@login_required
def usage_and_plan(request, slug):
    """Everything on this page comes through the seam — the future Billing
    Core integration swaps the provider, not this view."""
    organization = get_object_or_404(Organization, slug=slug)
    membership = organization.memberships.filter(
        user=request.user, status=Membership.ACTIVE
    ).first()
    if not membership:
        return HttpResponseForbidden("not a member")

    summary = get_provider().summarize(organization)
    return render(
        request,
        "billing_seam/usage_and_plan.html",
        {
            "organization": organization,
            "summary": summary,
            "seat_total": format_minor(summary.seat_total_minor),
            "seat_price": format_minor(summary.seat_price_minor),
            "overage_total": format_minor(summary.overage_total_minor),
            "total": format_minor(summary.total_minor),
        },
    )
