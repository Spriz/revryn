from django.contrib import messages
from django.contrib.auth import authenticate, login, logout
from django.contrib.auth.decorators import login_required
from django.db import transaction
from django.shortcuts import get_object_or_404, redirect, render
from django.utils import timezone
from django.utils.text import slugify

from work.models import record_activity

from .models import Invitation, Membership, Organization, User


def _admin_membership_or_404(user, slug):
    organization = get_object_or_404(Organization, slug=slug)
    membership = get_object_or_404(
        Membership, organization=organization, user=user, status=Membership.ACTIVE
    )
    return organization, membership


def register(request):
    if request.method == "POST":
        email = request.POST.get("email", "").strip().lower()
        password = request.POST.get("password", "")
        full_name = request.POST.get("full_name", "").strip()
        if not email or len(password) < 8:
            messages.error(request, "Email and a password of at least 8 characters are required.")
        elif User.objects.filter(email=email).exists():
            messages.error(request, "That email already has an account — sign in instead.")
        else:
            user = User.objects.create_user(email=email, password=password, full_name=full_name)
            login(request, user)
            next_url = request.GET.get("next")
            return redirect(next_url or "home")
    return render(request, "accounts/register.html")


def login_view(request):
    if request.method == "POST":
        user = authenticate(
            request,
            username=request.POST.get("email", "").strip().lower(),
            password=request.POST.get("password", ""),
        )
        if user:
            login(request, user)
            return redirect(request.GET.get("next") or "home")
        messages.error(request, "Wrong email or password.")
    return render(request, "accounts/login.html")


def logout_view(request):
    logout(request)
    return redirect("login")


@login_required
def create_organization(request):
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        if name:
            base = slugify(name) or "org"
            slug, n = base, 2
            while Organization.objects.filter(slug=slug).exists():
                slug, n = f"{base}-{n}", n + 1
            with transaction.atomic():
                organization = Organization.objects.create(name=name, slug=slug)
                Membership.objects.create(
                    organization=organization, user=request.user, role=Membership.OWNER
                )
                record_activity(
                    organization, request.user, "org.created", f"Created organization “{name}”"
                )
            return redirect("organization_home", slug=organization.slug)
        messages.error(request, "A name is required.")
    return render(request, "accounts/create_organization.html")


@login_required
def members(request, slug):
    organization, membership = _admin_membership_or_404(request.user, slug)
    return render(
        request,
        "accounts/members.html",
        {
            "organization": organization,
            "my_membership": membership,
            "memberships": organization.memberships.filter(status=Membership.ACTIVE)
            .select_related("user")
            .order_by("created_at"),
            "invitations": organization.invitations.order_by("-created_at"),
            "roles": Membership.ROLE_CHOICES,
        },
    )


@login_required
def invite(request, slug):
    organization, membership = _admin_membership_or_404(request.user, slug)
    if request.method == "POST" and membership.is_admin():
        email = request.POST.get("email", "").strip().lower()
        role = request.POST.get("role", Membership.MEMBER)
        if role not in dict(Membership.ROLE_CHOICES):
            role = Membership.MEMBER
        if email:
            invitation = Invitation.objects.create(
                organization=organization, email=email, role=role, invited_by=request.user
            )
            record_activity(
                organization, request.user, "member.invited", f"Invited {email} as {role}"
            )
            messages.success(
                request,
                f"Share this single-use link with {email}: "
                + request.build_absolute_uri(f"/invitations/{invitation.token}/"),
            )
    return redirect("members", slug=slug)


@login_required
def accept_invitation(request, token):
    invitation = get_object_or_404(Invitation, token=token)
    if request.method == "POST":
        try:
            invitation.accept(request.user)
        except ValueError as error:
            messages.error(request, str(error))
            return redirect("home")
        record_activity(
            invitation.organization,
            request.user,
            "member.joined",
            f"{request.user.email} joined as {invitation.role}",
        )
        return redirect("organization_home", slug=invitation.organization.slug)
    return render(request, "accounts/accept_invitation.html", {"invitation": invitation})


@login_required
def revoke_invitation(request, slug, invitation_id):
    organization, membership = _admin_membership_or_404(request.user, slug)
    if request.method == "POST" and membership.is_admin():
        invitation = get_object_or_404(Invitation, id=invitation_id, organization=organization)
        if invitation.is_pending():
            invitation.revoked_at = timezone.now()
            invitation.save(update_fields=["revoked_at"])
    return redirect("members", slug=slug)


@login_required
def change_role(request, slug, membership_id):
    organization, my_membership = _admin_membership_or_404(request.user, slug)
    if request.method == "POST" and my_membership.is_admin():
        target = get_object_or_404(Membership, id=membership_id, organization=organization)
        role = request.POST.get("role")
        owners = organization.memberships.filter(
            role=Membership.OWNER, status=Membership.ACTIVE
        ).count()
        if role not in dict(Membership.ROLE_CHOICES):
            messages.error(request, "Unknown role.")
        elif target.role == Membership.OWNER and role != Membership.OWNER and owners <= 1:
            messages.error(request, "The last owner cannot be demoted.")
        else:
            target.role = role
            target.save(update_fields=["role"])
            record_activity(
                organization,
                request.user,
                "member.role_changed",
                f"{target.user.email} is now {role}",
            )
    return redirect("members", slug=slug)


@login_required
def remove_member(request, slug, membership_id):
    organization, my_membership = _admin_membership_or_404(request.user, slug)
    if request.method == "POST" and my_membership.is_admin():
        target = get_object_or_404(Membership, id=membership_id, organization=organization)
        owners = organization.memberships.filter(
            role=Membership.OWNER, status=Membership.ACTIVE
        ).count()
        if target.role == Membership.OWNER and owners <= 1:
            messages.error(request, "The last owner cannot be removed.")
        else:
            target.status = Membership.REMOVED
            target.save(update_fields=["status"])
            record_activity(
                organization, request.user, "member.removed", f"Removed {target.user.email}"
            )
    return redirect("members", slug=slug)
