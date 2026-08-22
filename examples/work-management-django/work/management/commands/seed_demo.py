"""Seed data for evaluators (BC-US-151): one organization, two projects,
tasks across the flow, labels, an automation rule, and a burst of real
automation runs so the usage-and-plan page shows live numbers.

    make seed   →  sign in as demo@driftbord.example / sikkerhed123
"""

from django.core.management.base import BaseCommand

from accounts.models import Membership, Organization, User
from automation.models import Rule, execute_rules_for_move
from work.models import Board, Column, Label, Project, Task


class Command(BaseCommand):
    help = "Seeds a demo organization with projects, tasks, and automation."

    def handle(self, *args, **options):
        demo, _ = User.objects.get_or_create(
            email="demo@driftbord.example", defaults={"full_name": "Demo Bruger"}
        )
        demo.set_password("sikkerhed123")
        demo.save()

        organization, created = Organization.objects.get_or_create(
            slug="fjordlys", defaults={"name": "Fjordlys Software"}
        )
        Membership.objects.get_or_create(
            organization=organization, user=demo, defaults={"role": Membership.OWNER}
        )
        for n in range(1, 4):
            colleague, _ = User.objects.get_or_create(
                email=f"kollega{n}@driftbord.example", defaults={"full_name": f"Kollega {n}"}
            )
            colleague.set_password("sikkerhed123")
            colleague.save()
            Membership.objects.get_or_create(organization=organization, user=colleague)

        if created or not organization.projects.exists():
            project = Project.objects.create(
                organization=organization,
                name="Website relaunch",
                description="Everything for the Q4 site launch.",
            )
            board = Board.objects.create(project=project, name="Launch board")
            todo = Column.objects.create(board=board, name="Backlog", position=0)
            doing = Column.objects.create(board=board, name="In progress", position=1)
            review = Column.objects.create(board=board, name="Review", position=2)
            Column.objects.create(board=board, name="Done", position=3)

            urgent = Label.objects.create(project=project, name="urgent", color="#dc2626")
            Label.objects.create(project=project, name="design", color="#7c3aed")

            rule = Rule.objects.create(
                project=project,
                name="Flag reviews",
                trigger_column=review,
                action=Rule.ADD_LABEL,
                add_label=urgent,
            )

            titles = [
                "Draft new landing copy",
                "Design pricing page",
                "Migrate blog posts",
                "Set up analytics",
                "Accessibility pass",
                "Launch checklist",
            ]
            for position, title in enumerate(titles):
                Task.objects.create(
                    column=todo, title=title, position=position, created_by=demo
                )

            # Real workflow: move a few tasks through review so the rule
            # runs and the seam has metered usage to show.
            for task in list(todo.tasks.all())[:3]:
                task.column = doing
                task.save(update_fields=["column"])
                task.column = review
                task.save(update_fields=["column"])
                execute_rules_for_move(task, review, demo)

            self.stdout.write(self.style.SUCCESS(f"Seeded {organization.name} (rule: {rule.name})"))
        else:
            self.stdout.write("Demo organization already present — nothing to do.")

        self.stdout.write("Sign in: demo@driftbord.example / sikkerhed123")
