"""Integrated-mode hooks: real product events flow to Billing Core.

Failures never break the product action — they log loudly instead; the
durable source of truth for retry is the local data (seats can re-sync,
usage re-push is idempotent by external event id).
"""

import logging

from django.db.models.signals import post_save
from django.dispatch import receiver

from accounts.models import Membership
from automation.models import AutomationRun

from . import provisioning
from .client import BillingCoreError

logger = logging.getLogger("driftbord.billing_core")


@receiver(post_save, sender=Membership)
def membership_changed(sender, instance, **kwargs):
    try:
        provisioning.sync_seats(instance.organization)
    except BillingCoreError as error:
        logger.error("seat sync failed for %s: %s", instance.organization.slug, error)


@receiver(post_save, sender=AutomationRun)
def automation_ran(sender, instance, created, **kwargs):
    if not created:
        return
    try:
        provisioning.push_automation_run(instance)
    except BillingCoreError as error:
        logger.error("usage push failed for run %s: %s", instance.id, error)
