"""Automation rules and runs (BC-US-151).

Rules fire from REAL application workflows — moving a task into a column
executes the matching rules synchronously — and every execution records an
AutomationRun. AutomationRun is the metered-usage source the billing seam
counts; usage never comes from a billing-demo screen (SPEC acceptance).
"""

from django.db import models
from django.utils import timezone

from work.models import Column, Project, Task, notify, record_activity


class Rule(models.Model):
    ASSIGN, ADD_LABEL, NOTIFY_CREATOR = "assign", "add_label", "notify_creator"
    ACTION_CHOICES = [
        (ASSIGN, "Assign a member"),
        (ADD_LABEL, "Add a label"),
        (NOTIFY_CREATOR, "Notify the task creator"),
    ]

    project = models.ForeignKey(Project, on_delete=models.CASCADE, related_name="rules")
    name = models.CharField(max_length=200)
    trigger_column = models.ForeignKey(
        Column,
        on_delete=models.CASCADE,
        related_name="rules",
        help_text="fires when a task is moved into this column",
    )
    action = models.CharField(max_length=20, choices=ACTION_CHOICES)
    assign_to = models.ForeignKey(
        "accounts.User", on_delete=models.SET_NULL, null=True, blank=True
    )
    add_label = models.ForeignKey(
        "work.Label", on_delete=models.SET_NULL, null=True, blank=True
    )
    enabled = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name


class AutomationRun(models.Model):
    """One metered automation execution — the usage unit."""

    SUCCEEDED, SKIPPED = "succeeded", "skipped"

    rule = models.ForeignKey(Rule, on_delete=models.CASCADE, related_name="runs")
    task = models.ForeignKey(Task, on_delete=models.SET_NULL, null=True)
    organization = models.ForeignKey(
        "accounts.Organization", on_delete=models.CASCADE, related_name="automation_runs"
    )
    status = models.CharField(max_length=12, default=SUCCEEDED)
    detail = models.CharField(max_length=200, blank=True)
    ran_at = models.DateTimeField(default=timezone.now)

    class Meta:
        ordering = ["-ran_at"]


def execute_rules_for_move(task, column, actor):
    """Runs every enabled rule of the target column against the moved task.

    Returns the created AutomationRun rows. Called from the real move-task
    workflow — this is where metered usage originates.
    """
    runs = []
    organization = column.board.project.organization

    for rule in column.rules.filter(enabled=True).select_related("assign_to", "add_label"):
        status, detail = AutomationRun.SUCCEEDED, ""

        if rule.action == Rule.ASSIGN and rule.assign_to:
            task.assignee = rule.assign_to
            task.save(update_fields=["assignee"])
            notify(rule.assign_to, f"You were auto-assigned “{task.title}”")
            detail = f"assigned {rule.assign_to.email}"
        elif rule.action == Rule.ADD_LABEL and rule.add_label:
            task.labels.add(rule.add_label)
            detail = f"labelled {rule.add_label.name}"
        elif rule.action == Rule.NOTIFY_CREATOR and task.created_by:
            notify(task.created_by, f"“{task.title}” reached {column.name}")
            detail = "notified creator"
        else:
            status, detail = AutomationRun.SKIPPED, "rule target missing"

        run = AutomationRun.objects.create(
            rule=rule, task=task, organization=organization, status=status, detail=detail
        )
        record_activity(
            organization,
            actor,
            "automation.ran",
            f"Automation “{rule.name}” {detail or status} on “{task.title}”",
            task=task,
        )
        runs.append(run)

    return runs
