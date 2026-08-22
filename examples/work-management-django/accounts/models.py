"""Identity and organization membership for the showcase (BC-US-151).

Mirrors the global-identity-with-local-roles model: one user, many
organizations, explicit per-organization roles. Invitations are
single-use tokens bound to an email.
"""

import secrets

from django.conf import settings
from django.contrib.auth.models import AbstractUser, BaseUserManager
from django.db import models
from django.utils import timezone


class UserManager(BaseUserManager):
    use_in_migrations = True

    def _create_user(self, email, password, **extra):
        if not email:
            raise ValueError("email is required")
        user = self.model(email=self.normalize_email(email), **extra)
        user.set_password(password)
        user.save(using=self._db)
        return user

    def create_user(self, email, password=None, **extra):
        extra.setdefault("is_staff", False)
        extra.setdefault("is_superuser", False)
        return self._create_user(email, password, **extra)

    def create_superuser(self, email, password=None, **extra):
        extra.setdefault("is_staff", True)
        extra.setdefault("is_superuser", True)
        return self._create_user(email, password, **extra)


class User(AbstractUser):
    username = None
    email = models.EmailField(unique=True)
    full_name = models.CharField(max_length=200, blank=True)

    USERNAME_FIELD = "email"
    REQUIRED_FIELDS = []

    objects = UserManager()

    def __str__(self):
        return self.email

    @property
    def display_name(self):
        return self.full_name or self.email


class Organization(models.Model):
    name = models.CharField(max_length=200)
    slug = models.SlugField(unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    def role_of(self, user):
        membership = self.memberships.filter(user=user, status=Membership.ACTIVE).first()
        return membership.role if membership else None

    def active_member_count(self):
        return self.memberships.filter(status=Membership.ACTIVE).count()


class Membership(models.Model):
    OWNER, ADMIN, MEMBER = "owner", "admin", "member"
    ROLE_CHOICES = [(OWNER, "Owner"), (ADMIN, "Admin"), (MEMBER, "Member")]
    ACTIVE, REMOVED = "active", "removed"

    organization = models.ForeignKey(
        Organization, on_delete=models.CASCADE, related_name="memberships"
    )
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="memberships"
    )
    role = models.CharField(max_length=10, choices=ROLE_CHOICES, default=MEMBER)
    status = models.CharField(max_length=10, default=ACTIVE)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["organization", "user"], name="one_membership_per_org"
            )
        ]

    def is_admin(self):
        return self.role in (self.OWNER, self.ADMIN)


class Invitation(models.Model):
    organization = models.ForeignKey(
        Organization, on_delete=models.CASCADE, related_name="invitations"
    )
    email = models.EmailField()
    role = models.CharField(
        max_length=10, choices=Membership.ROLE_CHOICES, default=Membership.MEMBER
    )
    token = models.CharField(max_length=64, unique=True, default=secrets.token_urlsafe)
    invited_by = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.SET_NULL, null=True
    )
    created_at = models.DateTimeField(auto_now_add=True)
    accepted_at = models.DateTimeField(null=True, blank=True)
    revoked_at = models.DateTimeField(null=True, blank=True)

    def is_pending(self):
        return self.accepted_at is None and self.revoked_at is None

    def accept(self, user):
        """Single-use, email-bound acceptance creating the membership."""
        if not self.is_pending():
            raise ValueError("invitation is not pending")
        if user.email.lower() != self.email.lower():
            raise ValueError("invitation was issued to a different email")
        membership, _created = Membership.objects.update_or_create(
            organization=self.organization,
            user=user,
            defaults={"role": self.role, "status": Membership.ACTIVE},
        )
        self.accepted_at = timezone.now()
        self.save(update_fields=["accepted_at"])
        return membership
