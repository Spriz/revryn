"""Integration-mode switch (BC-US-151 final milestone, BC-US-153).

Integrated mode is opt-in via environment; standalone remains the default
and keeps its full behavior and test suite (INV-031).
"""

import os


def enabled() -> bool:
    return os.environ.get("DRIFTBORD_BILLING") == "integrated"


def config() -> dict:
    return {
        "url": os.environ.get("BILLING_CORE_URL", "http://localhost:4000"),
        "token": os.environ.get("BILLING_CORE_TOKEN", ""),
        "team_id": os.environ.get("BILLING_CORE_TEAM_ID", ""),
    }
