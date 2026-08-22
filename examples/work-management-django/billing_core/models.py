from django.db import models

from accounts.models import Organization


class BillingCoreLink(models.Model):
    """Billing Core identities for one Driftbord organization."""

    organization = models.OneToOneField(
        Organization, on_delete=models.CASCADE, related_name="billing_core_link"
    )
    customer_id = models.CharField(max_length=64)
    contract_id = models.CharField(max_length=64)
    subscription_id = models.CharField(max_length=64)
    plan_version_id = models.CharField(max_length=64)
    created_at = models.DateTimeField(auto_now_add=True)
