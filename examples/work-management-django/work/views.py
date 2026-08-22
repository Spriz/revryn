from django.contrib import messages
from django.contrib.auth.decorators import login_required
from django.db.models import Q
from django.http import HttpResponseForbidden
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone

from accounts.models import Membership, Organization
from automation.models import execute_rules_for_move

from .models import (
    AttachmentMeta,
    Board,
    Column,
    Comment,
    Label,
    Notification,
    Project,
    SavedFilter,
    Task,
    notify,
    record_activity,
)


def _membership_or_none(user, organization):
    return organization.memberships.filter(user=user, status=Membership.ACTIVE).first()


def _require_org(user, slug):
    organization = get_object_or_404(Organization, slug=slug)
    membership = _membership_or_none(user, organization)
    return (organization, membership) if membership else (organization, None)


def _require_project(user, project_id):
    project = get_object_or_404(
        Project.objects.select_related("organization"), id=project_id
    )
    membership = _membership_or_none(user, project.organization)
    return project, membership


@login_required
def home(request):
    memberships = (
        request.user.memberships.filter(status=Membership.ACTIVE)
        .select_related("organization")
        .order_by("organization__name")
    )
    return render(request, "work/home.html", {"memberships": memberships})


@login_required
def organization_home(request, slug):
    organization, membership = _require_org(request.user, slug)
    if not membership:
        return HttpResponseForbidden("not a member")
    return render(
        request,
        "work/organization_home.html",
        {
            "organization": organization,
            "membership": membership,
            "projects": organization.projects.filter(archived=False).order_by("name"),
        },
    )


@login_required
def create_project(request, slug):
    organization, membership = _require_org(request.user, slug)
    if not membership:
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        if name:
            project = Project.objects.create(
                organization=organization,
                name=name,
                description=request.POST.get("description", ""),
            )
            board = Board.objects.create(project=project, name="Main board")
            for position, column in enumerate(["Backlog", "In progress", "Done"]):
                Column.objects.create(board=board, name=column, position=position)
            record_activity(
                organization, request.user, "project.created", f"Created project “{name}”"
            )
            return redirect("project_detail", project_id=project.id)
        messages.error(request, "A name is required.")
    return render(request, "work/create_project.html", {"organization": organization})


@login_required
def project_detail(request, project_id):
    project, membership = _require_project(request.user, project_id)
    if not membership:
        return HttpResponseForbidden("not a member")
    return render(
        request,
        "work/project_detail.html",
        {
            "project": project,
            "boards": project.boards.order_by("name"),
            "labels": project.labels.order_by("name"),
        },
    )


@login_required
def create_board(request, project_id):
    project, membership = _require_project(request.user, project_id)
    if not membership:
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        if name:
            board = Board.objects.create(project=project, name=name)
            return redirect("board_detail", board_id=board.id)
    return redirect("project_detail", project_id=project.id)


@login_required
def board_detail(request, board_id):
    board = get_object_or_404(
        Board.objects.select_related("project__organization"), id=board_id
    )
    membership = _membership_or_none(request.user, board.project.organization)
    if not membership:
        return HttpResponseForbidden("not a member")
    columns = board.columns.prefetch_related("tasks__labels", "tasks__assignee")
    members = board.project.organization.memberships.filter(
        status=Membership.ACTIVE
    ).select_related("user")
    return render(
        request,
        "work/board_detail.html",
        {"board": board, "columns": columns, "members": members},
    )


@login_required
def create_column(request, board_id):
    board = get_object_or_404(Board.objects.select_related("project__organization"), id=board_id)
    if not _membership_or_none(request.user, board.project.organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        if name:
            Column.objects.create(board=board, name=name, position=board.columns.count())
    return redirect("board_detail", board_id=board.id)


@login_required
def create_task(request, column_id):
    column = get_object_or_404(
        Column.objects.select_related("board__project__organization"), id=column_id
    )
    organization = column.board.project.organization
    if not _membership_or_none(request.user, organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        title = request.POST.get("title", "").strip()
        if title:
            task = Task.objects.create(
                column=column,
                title=title,
                created_by=request.user,
                position=column.tasks.count(),
                due_date=request.POST.get("due_date") or None,
            )
            record_activity(
                organization,
                request.user,
                "task.created",
                f"Created “{title}” in {column.name}",
                task=task,
            )
    return redirect("board_detail", board_id=column.board_id)


@login_required
def task_detail(request, task_id):
    task = get_object_or_404(
        Task.objects.select_related("column__board__project__organization", "assignee"),
        id=task_id,
    )
    organization = task.project.organization
    if not _membership_or_none(request.user, organization):
        return HttpResponseForbidden("not a member")
    return render(
        request,
        "work/task_detail.html",
        {
            "task": task,
            "organization": organization,
            "columns": task.column.board.columns.all(),
            "members": organization.memberships.filter(status=Membership.ACTIVE).select_related(
                "user"
            ),
            "project_labels": task.project.labels.order_by("name"),
        },
    )


@login_required
def move_task(request, task_id):
    task = get_object_or_404(
        Task.objects.select_related("column__board__project__organization"), id=task_id
    )
    organization = task.project.organization
    if not _membership_or_none(request.user, organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        column = get_object_or_404(
            Column, id=request.POST.get("column_id"), board=task.column.board
        )
        if column.id != task.column_id:
            previous = task.column.name
            task.column = column
            task.position = column.tasks.count()
            task.save(update_fields=["column", "position"])
            record_activity(
                organization,
                request.user,
                "task.moved",
                f"Moved “{task.title}” from {previous} to {column.name}",
                task=task,
            )
            # Real workflow → automation → metered usage (BC-US-151).
            execute_rules_for_move(task, column, request.user)
    return redirect(request.POST.get("next") or "board_detail", board_id=task.column.board_id)


@login_required
def add_comment(request, task_id):
    task = get_object_or_404(
        Task.objects.select_related("column__board__project__organization"), id=task_id
    )
    organization = task.project.organization
    if not _membership_or_none(request.user, organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        body = request.POST.get("body", "").strip()
        if body:
            Comment.objects.create(task=task, author=request.user, body=body)
            record_activity(
                organization, request.user, "task.commented", f"Commented on “{task.title}”", task=task
            )
            if task.assignee and task.assignee != request.user:
                notify(task.assignee, f"New comment on “{task.title}”")
    return redirect("task_detail", task_id=task.id)


@login_required
def assign_task(request, task_id):
    task = get_object_or_404(
        Task.objects.select_related("column__board__project__organization"), id=task_id
    )
    organization = task.project.organization
    if not _membership_or_none(request.user, organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        assignee_id = request.POST.get("assignee_id")
        if assignee_id:
            membership = get_object_or_404(
                Membership,
                user_id=assignee_id,
                organization=organization,
                status=Membership.ACTIVE,
            )
            task.assignee = membership.user
            notify(membership.user, f"You were assigned “{task.title}”")
        else:
            task.assignee = None
        task.save(update_fields=["assignee"])
        record_activity(
            organization,
            request.user,
            "task.assigned",
            f"Assigned “{task.title}” to {task.assignee.email if task.assignee else 'nobody'}",
            task=task,
        )
        due = request.POST.get("due_date")
        if due is not None:
            task.due_date = due or None
            task.save(update_fields=["due_date"])
    return redirect("task_detail", task_id=task.id)


@login_required
def toggle_label(request, task_id):
    task = get_object_or_404(
        Task.objects.select_related("column__board__project__organization"), id=task_id
    )
    if not _membership_or_none(request.user, task.project.organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        label = get_object_or_404(Label, id=request.POST.get("label_id"), project=task.project)
        if task.labels.filter(id=label.id).exists():
            task.labels.remove(label)
        else:
            task.labels.add(label)
    return redirect("task_detail", task_id=task.id)


@login_required
def create_label(request, project_id):
    project, membership = _require_project(request.user, project_id)
    if not membership:
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        if name and not project.labels.filter(name=name).exists():
            Label.objects.create(
                project=project, name=name, color=request.POST.get("color") or "#5b8def"
            )
    return redirect("project_detail", project_id=project.id)


@login_required
def add_attachment_meta(request, task_id):
    task = get_object_or_404(
        Task.objects.select_related("column__board__project__organization"), id=task_id
    )
    if not _membership_or_none(request.user, task.project.organization):
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        filename = request.POST.get("filename", "").strip()
        if filename:
            AttachmentMeta.objects.create(
                task=task,
                filename=filename,
                content_type=request.POST.get("content_type", ""),
                byte_size=int(request.POST.get("byte_size") or 0),
                added_by=request.user,
            )
    return redirect("task_detail", task_id=task.id)


@login_required
def search(request, slug):
    organization, membership = _require_org(request.user, slug)
    if not membership:
        return HttpResponseForbidden("not a member")
    query = request.GET.get("q", "").strip()
    tasks = Task.objects.none()
    if query:
        tasks = (
            Task.objects.filter(column__board__project__organization=organization)
            .filter(Q(title__icontains=query) | Q(description__icontains=query))
            .select_related("column__board__project", "assignee")[:50]
        )
    saved = SavedFilter.objects.filter(organization=organization, user=request.user)
    return render(
        request,
        "work/search.html",
        {"organization": organization, "query": query, "tasks": tasks, "saved_filters": saved},
    )


@login_required
def save_filter(request, slug):
    organization, membership = _require_org(request.user, slug)
    if not membership:
        return HttpResponseForbidden("not a member")
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        query = request.POST.get("q", "").strip()
        if name and query:
            SavedFilter.objects.update_or_create(
                organization=organization,
                user=request.user,
                name=name,
                defaults={"query": query},
            )
    return redirect(f"/orgs/{slug}/search/?q={request.POST.get('q', '')}")


@login_required
def notifications(request):
    rows = request.user.notifications.all()[:100]
    if request.method == "POST":
        request.user.notifications.filter(read_at__isnull=True).update(read_at=timezone.now())
        return redirect("notifications")
    return render(request, "work/notifications.html", {"rows": rows})


@login_required
def activity(request, slug):
    organization, membership = _require_org(request.user, slug)
    if not membership:
        return HttpResponseForbidden("not a member")
    return render(
        request,
        "work/activity.html",
        {
            "organization": organization,
            "rows": organization.activities.select_related("actor")[:200],
        },
    )
