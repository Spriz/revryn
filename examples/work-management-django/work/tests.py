from django.test import TestCase

from accounts.models import Membership, Organization, User
from work.models import Activity, Board, Column, Notification, Project, SavedFilter, Task


def workspace(email="lene@example.com", org="Nordlys"):
    user = User.objects.create_user(email=email, password="sikkerhed123")
    organization = Organization.objects.create(name=org, slug=org.lower())
    Membership.objects.create(organization=organization, user=user, role=Membership.OWNER)
    return user, organization


class ProjectAndBoardTests(TestCase):
    def setUp(self):
        self.user, self.organization = workspace()
        self.client.force_login(self.user)

    def test_new_project_scaffolds_a_default_board_with_columns(self):
        self.client.post(
            f"/orgs/{self.organization.slug}/projects/new/", {"name": "Website relaunch"}
        )
        project = Project.objects.get(name="Website relaunch")
        board = project.boards.get()
        self.assertEqual(
            list(board.columns.values_list("name", flat=True)),
            ["Backlog", "In progress", "Done"],
        )
        self.assertTrue(
            Activity.objects.filter(
                organization=self.organization, verb="project.created"
            ).exists()
        )

    def test_non_members_are_locked_out(self):
        outsider = User.objects.create_user(email="udenfor@example.com", password="sikkerhed123")
        self.client.post(f"/orgs/{self.organization.slug}/projects/new/", {"name": "Privat"})
        project = Project.objects.get(name="Privat")

        self.client.force_login(outsider)
        self.assertEqual(self.client.get(f"/projects/{project.id}/").status_code, 403)
        self.assertEqual(
            self.client.get(f"/orgs/{self.organization.slug}/").status_code, 403
        )


class TaskFlowTests(TestCase):
    def setUp(self):
        self.user, self.organization = workspace()
        self.client.force_login(self.user)
        self.project = Project.objects.create(organization=self.organization, name="Drift")
        self.board = Board.objects.create(project=self.project, name="Main")
        self.todo = Column.objects.create(board=self.board, name="Todo", position=0)
        self.done = Column.objects.create(board=self.board, name="Done", position=1)

    def test_create_move_and_history(self):
        self.client.post(f"/columns/{self.todo.id}/tasks/new/", {"title": "Skriv rapport"})
        task = Task.objects.get(title="Skriv rapport")
        self.assertEqual(task.created_by, self.user)

        self.client.post(f"/tasks/{task.id}/move/", {"column_id": self.done.id})
        task.refresh_from_db()
        self.assertEqual(task.column, self.done)

        verbs = list(
            Activity.objects.filter(task=task).values_list("verb", flat=True).order_by("id")
        )
        self.assertEqual(verbs, ["task.created", "task.moved"])

    def test_comment_notifies_the_assignee(self):
        colleague = User.objects.create_user(email="bo@example.com", password="sikkerhed123")
        Membership.objects.create(organization=self.organization, user=colleague)
        task = Task.objects.create(column=self.todo, title="Review", assignee=colleague)

        self.client.post(f"/tasks/{task.id}/comment/", {"body": "Kig på denne"})
        self.assertTrue(
            Notification.objects.filter(user=colleague, text__contains="Review").exists()
        )

    def test_assignment_is_membership_checked(self):
        stranger = User.objects.create_user(email="fremmed@example.com", password="sikkerhed123")
        task = Task.objects.create(column=self.todo, title="Sikkerhed")
        response = self.client.post(
            f"/tasks/{task.id}/assign/", {"assignee_id": stranger.id}
        )
        self.assertEqual(response.status_code, 404)
        task.refresh_from_db()
        self.assertIsNone(task.assignee)


class SearchTests(TestCase):
    def setUp(self):
        self.user, self.organization = workspace()
        self.client.force_login(self.user)
        project = Project.objects.create(organization=self.organization, name="Søgning")
        board = Board.objects.create(project=project, name="Main")
        column = Column.objects.create(board=board, name="Todo")
        Task.objects.create(column=column, title="Fakturering af kunder")
        Task.objects.create(column=column, title="Andet arbejde")

    def test_search_finds_by_title_and_saves_filters(self):
        response = self.client.get(f"/orgs/{self.organization.slug}/search/?q=Fakturering")
        self.assertContains(response, "Fakturering af kunder")
        self.assertNotContains(response, "Andet arbejde")

        self.client.post(
            f"/orgs/{self.organization.slug}/filters/save/",
            {"q": "Fakturering", "name": "Fakturaer"},
        )
        saved = SavedFilter.objects.get(name="Fakturaer")
        self.assertEqual(saved.query, "Fakturering")
