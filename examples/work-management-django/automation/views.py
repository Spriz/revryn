from django.contrib.auth.decorators import login_required
from django.http import HttpResponseForbidden
from django.shortcuts import get_object_or_404, redirect, render

from accounts.models import Membership
from work.models import Column, Label, Project, record_activity

from .models import AutomationRun, Rule


def _project_membership(user, project_id):
    project = get_object_or_404(Project.objects.select_related("organization"), id=project_id)
    membership = project.organization.memberships.filter(
        user=user, status=Membership.ACTIVE
    ).first()
    return project, membership


@login_required
def rules(request, project_id):
    project, membership = _project_membership(request.user, project_id)
    if not membership:
        return HttpResponseForbidden("not a member")
    return render(
        request,
        "automation/rules.html",
        {
            "project": project,
            "rules": project.rules.select_related("trigger_column", "assign_to", "add_label"),
            "runs": AutomationRun.objects.filter(rule__project=project).select_related(
                "rule", "task"
            )[:50],
            "columns": Column.objects.filter(board__project=project).select_related("board"),
            "members": project.organization.memberships.filter(
                status=Membership.ACTIVE
            ).select_related("user"),
            "labels": project.labels.order_by("name"),
            "actions": Rule.ACTION_CHOICES,
        },
    )


@login_required
def create_rule(request, project_id):
    project, membership = _project_membership(request.user, project_id)
    if not membership:
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        action = request.POST.get("action")
        column = get_object_or_404(
            Column, id=request.POST.get("trigger_column_id"), board__project=project
        )
        if name and action in dict(Rule.ACTION_CHOICES):
            rule = Rule(project=project, name=name, trigger_column=column, action=action)
            if action == Rule.ASSIGN and request.POST.get("assign_to_id"):
                member = project.organization.memberships.filter(
                    user_id=request.POST["assign_to_id"], status=Membership.ACTIVE
                ).first()
                rule.assign_to = member.user if member else None
            if action == Rule.ADD_LABEL and request.POST.get("add_label_id"):
                rule.add_label = Label.objects.filter(
                    id=request.POST["add_label_id"], project=project
                ).first()
            rule.save()
            record_activity(
                project.organization,
                request.user,
                "automation.rule_created",
                f"Created rule “{name}” on {column.name}",
            )
    return redirect("rules", project_id=project.id)


@login_required
def toggle_rule(request, rule_id):
    rule = get_object_or_404(Rule.objects.select_related("project__organization"), id=rule_id)
    membership = rule.project.organization.memberships.filter(
        user=request.user, status=Membership.ACTIVE
    ).first()
    if not membership:
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        rule.enabled = not rule.enabled
        rule.save(update_fields=["enabled"])
    return redirect("rules", project_id=rule.project_id)
