from django.apps import AppConfig


class BillingCoreConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "billing_core"

    def ready(self):
        from . import integration

        if integration.enabled():
            from . import signals  # noqa: F401  (connects handlers)
