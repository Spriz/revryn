from django.test import TestCase

from accounts.models import Membership, Organization, User
from automation.models import AutomationRun, Rule
from work.models import Board, Column, Label, Notification, Project, Task


class AutomationTests(TestCase):
    def setUp(self):
        self.user = User.objects.create_user(email="rikke@example.com", password="sikkerhed123")
        self.organization = Organization.objects.create(name="Autoflow", slug="autoflow")
        Membership.objects.create(
            organization=self.organization, user=self.user, role=Membership.OWNER
        )
        self.client.force_login(self.user)
        self.project = Project.objects.create(organization=self.organization, name="Robot")
        board = Board.objects.create(project=self.project, name="Main")
        self.todo = Column.objects.create(board=board, name="Todo", position=0)
        self.review = Column.objects.create(board=board, name="Review", position=1)

    def test_moving_a_task_executes_rules_and_meters_a_run(self):
        label = Label.objects.create(project=self.project, name="needs-review")
        Rule.objects.create(
            project=self.project,
            name="Label on review",
            trigger_column=self.review,
            action=Rule.ADD_LABEL,
            add_label=label,
        )
        task = Task.objects.create(column=self.todo, title="Ship it", created_by=self.user)

        # The REAL move workflow is the only trigger (BC-US-151).
        self.client.post(f"/tasks/{task.id}/move/", {"column_id": self.review.id})

        task.refresh_from_db()
        self.assertIn(label, task.labels.all())
        run = AutomationRun.objects.get()
        self.assertEqual(run.organization, self.organization)
        self.assertEqual(run.status, AutomationRun.SUCCEEDED)

    def test_assign_rule_assigns_and_notifies(self):
        Rule.objects.create(
            project=self.project,
            name="Auto-assign reviews",
            trigger_column=self.review,
            action=Rule.ASSIGN,
            assign_to=self.user,
        )
        task = Task.objects.create(column=self.todo, title="Gennemse")
        self.client.post(f"/tasks/{task.id}/move/", {"column_id": self.review.id})

        task.refresh_from_db()
        self.assertEqual(task.assignee, self.user)
        self.assertTrue(Notification.objects.filter(user=self.user).exists())

    def test_disabled_rules_do_not_run_or_meter(self):
        Rule.objects.create(
            project=self.project,
            name="Sleeping",
            trigger_column=self.review,
            action=Rule.NOTIFY_CREATOR,
            enabled=False,
        )
        task = Task.objects.create(column=self.todo, title="Stille", created_by=self.user)
        self.client.post(f"/tasks/{task.id}/move/", {"column_id": self.review.id})
        self.assertEqual(AutomationRun.objects.count(), 0)

    def test_rule_with_missing_target_is_metered_as_skipped(self):
        Rule.objects.create(
            project=self.project,
            name="Broken",
            trigger_column=self.review,
            action=Rule.ASSIGN,
            assign_to=None,
        )
        task = Task.objects.create(column=self.todo, title="Uheld")
        self.client.post(f"/tasks/{task.id}/move/", {"column_id": self.review.id})
        run = AutomationRun.objects.get()
        self.assertEqual(run.status, AutomationRun.SKIPPED)
