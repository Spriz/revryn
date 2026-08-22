from django.contrib import admin
from django.urls import path

from accounts import views as accounts
from automation import views as automation
from billing_seam import views as billing
from work import views as work

urlpatterns = [
    path("admin/", admin.site.urls),
    # identity + organizations
    path("register/", accounts.register, name="register"),
    path("login/", accounts.login_view, name="login"),
    path("logout/", accounts.logout_view, name="logout"),
    path("orgs/new/", accounts.create_organization, name="create_organization"),
    path("orgs/<slug:slug>/members/", accounts.members, name="members"),
    path("orgs/<slug:slug>/members/<int:membership_id>/role/", accounts.change_role, name="change_role"),
    path("orgs/<slug:slug>/members/<int:membership_id>/remove/", accounts.remove_member, name="remove_member"),
    path("orgs/<slug:slug>/invitations/", accounts.invite, name="invite"),
    path("orgs/<slug:slug>/invitations/<int:invitation_id>/revoke/", accounts.revoke_invitation, name="revoke_invitation"),
    path("invitations/<str:token>/", accounts.accept_invitation, name="accept_invitation"),
    # work management
    path("", work.home, name="home"),
    path("orgs/<slug:slug>/", work.organization_home, name="organization_home"),
    path("orgs/<slug:slug>/projects/new/", work.create_project, name="create_project"),
    path("projects/<int:project_id>/", work.project_detail, name="project_detail"),
    path("projects/<int:project_id>/boards/new/", work.create_board, name="create_board"),
    path("boards/<int:board_id>/", work.board_detail, name="board_detail"),
    path("boards/<int:board_id>/columns/new/", work.create_column, name="create_column"),
    path("columns/<int:column_id>/tasks/new/", work.create_task, name="create_task"),
    path("tasks/<int:task_id>/", work.task_detail, name="task_detail"),
    path("tasks/<int:task_id>/move/", work.move_task, name="move_task"),
    path("tasks/<int:task_id>/comment/", work.add_comment, name="add_comment"),
    path("tasks/<int:task_id>/assign/", work.assign_task, name="assign_task"),
    path("tasks/<int:task_id>/labels/", work.toggle_label, name="toggle_label"),
    path("tasks/<int:task_id>/attachments/", work.add_attachment_meta, name="add_attachment_meta"),
    path("projects/<int:project_id>/labels/new/", work.create_label, name="create_label"),
    path("orgs/<slug:slug>/search/", work.search, name="search"),
    path("orgs/<slug:slug>/filters/save/", work.save_filter, name="save_filter"),
    path("notifications/", work.notifications, name="notifications"),
    path("orgs/<slug:slug>/activity/", work.activity, name="activity"),
    # automation
    path("projects/<int:project_id>/rules/", automation.rules, name="rules"),
    path("projects/<int:project_id>/rules/new/", automation.create_rule, name="create_rule"),
    path("rules/<int:rule_id>/toggle/", automation.toggle_rule, name="toggle_rule"),
    # billing seam
    path("orgs/<slug:slug>/billing/", billing.usage_and_plan, name="usage_and_plan"),
]
