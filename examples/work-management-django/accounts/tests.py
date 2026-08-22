from django.test import TestCase

from .models import Invitation, Membership, Organization, User


def make_user(email="anna@example.com"):
    return User.objects.create_user(email=email, password="sikkerhed123")


class AuthFlowTests(TestCase):
    def test_register_signs_in_and_lands_home(self):
        response = self.client.post(
            "/register/",
            {"email": "ny@example.com", "password": "sikkerhed123", "full_name": "Ny Bruger"},
        )
        self.assertRedirects(response, "/")
        self.assertTrue(User.objects.filter(email="ny@example.com").exists())

    def test_login_rejects_wrong_password(self):
        make_user()
        response = self.client.post(
            "/login/", {"email": "anna@example.com", "password": "forkert"}
        )
        self.assertContains(response, "Wrong email or password")


class OrganizationTests(TestCase):
    def setUp(self):
        self.user = make_user()
        self.client.force_login(self.user)

    def test_creator_becomes_owner(self):
        self.client.post("/orgs/new/", {"name": "Fjordlys Studio"})
        organization = Organization.objects.get(name="Fjordlys Studio")
        self.assertEqual(organization.role_of(self.user), Membership.OWNER)

    def test_last_owner_cannot_be_demoted_or_removed(self):
        self.client.post("/orgs/new/", {"name": "Solo"})
        organization = Organization.objects.get(name="Solo")
        membership = organization.memberships.get()

        self.client.post(
            f"/orgs/{organization.slug}/members/{membership.id}/role/", {"role": "member"}
        )
        membership.refresh_from_db()
        self.assertEqual(membership.role, Membership.OWNER)

        self.client.post(f"/orgs/{organization.slug}/members/{membership.id}/remove/")
        membership.refresh_from_db()
        self.assertEqual(membership.status, Membership.ACTIVE)


class InvitationTests(TestCase):
    def setUp(self):
        self.owner = make_user("ejer@example.com")
        self.client.force_login(self.owner)
        self.client.post("/orgs/new/", {"name": "Havblik"})
        self.organization = Organization.objects.get(name="Havblik")

    def test_invitation_is_email_bound_and_single_use(self):
        invitation = Invitation.objects.create(
            organization=self.organization, email="gaest@example.com", invited_by=self.owner
        )

        wrong_user = make_user("forkert@example.com")
        with self.assertRaises(ValueError):
            invitation.accept(wrong_user)

        right_user = make_user("gaest@example.com")
        membership = invitation.accept(right_user)
        self.assertEqual(membership.role, Membership.MEMBER)
        with self.assertRaises(ValueError):
            invitation.accept(right_user)

    def test_accept_flow_through_the_browser_urls(self):
        invitation = Invitation.objects.create(
            organization=self.organization,
            email="med@example.com",
            role=Membership.ADMIN,
            invited_by=self.owner,
        )
        invitee = make_user("med@example.com")
        self.client.force_login(invitee)
        response = self.client.post(f"/invitations/{invitation.token}/")
        self.assertRedirects(response, f"/orgs/{self.organization.slug}/")
        self.assertEqual(self.organization.role_of(invitee), Membership.ADMIN)
