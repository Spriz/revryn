"""Minimal Billing Core GraphQL client (public contract only, INV-030).

Standard-library HTTP so the showcase gains no dependency. Failures are
classified so operators can distinguish showcase defects, GraphQL
incompatibility, authentication failures, and billing-domain rejections
(BC-US-153).
"""

import json
import urllib.error
import urllib.request
import uuid

from . import integration


class BillingCoreError(Exception):
    """Base for everything the adapter can raise."""


class ConfigurationError(BillingCoreError):
    pass


class AuthenticationError(BillingCoreError):
    pass


class ContractError(BillingCoreError):
    """The GraphQL contract rejected the document (incompatibility)."""


class DomainRejection(BillingCoreError):
    """Billing Core accepted the request and said no (typed problem)."""

    def __init__(self, code, message):
        super().__init__(f"{code}: {message}")
        self.code = code


class Client:
    def __init__(self, url=None, token=None, team_id=None):
        cfg = integration.config()
        self.url = (url or cfg["url"]).rstrip("/") + "/graphql"
        self.token = token or cfg["token"]
        self.team_id = team_id or cfg["team_id"]
        if not self.token or not self.team_id:
            raise ConfigurationError(
                "BILLING_CORE_TOKEN and BILLING_CORE_TEAM_ID are required in integrated mode"
            )

    def execute(self, document, variables=None):
        payload = json.dumps({"query": document, "variables": variables or {}}).encode()
        request = urllib.request.Request(
            self.url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self.token}",
                "X-Correlation-Id": str(uuid.uuid4()),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise AuthenticationError(f"HTTP {error.code} from Billing Core") from error
            raise ContractError(f"HTTP {error.code} from Billing Core") from error
        except urllib.error.URLError as error:
            raise ContractError(f"Billing Core unreachable: {error.reason}") from error

        if body.get("errors"):
            first = body["errors"][0]
            code = (first.get("extensions") or {}).get("code") or first.get("code")
            if code in ("UNAUTHENTICATED", "UNAUTHORIZED"):
                raise AuthenticationError(first.get("message", code))
            raise ContractError(first.get("message", "GraphQL error"))
        return body["data"]

    def mutate(self, field, document, variables):
        """Executes a typed-union mutation; problem members raise
        DomainRejection, success payloads return."""
        payload = self.execute(document, variables)[field]
        typename = payload.get("__typename", "")
        if typename.endswith("Problem") or typename in ("VersionConflict", "IdempotencyConflict", "UsageEventConflict"):
            raise DomainRejection(payload.get("code", typename), payload.get("message", ""))
        return payload
