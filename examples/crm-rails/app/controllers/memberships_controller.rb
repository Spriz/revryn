class MembershipsController < ApplicationController
  before_action :require_login, :require_member

  def index
    @memberships = current_organization.memberships.active.includes(:user)
    @invitations = current_organization.invitations.order(created_at: :desc)
  end

  def update
    return head :forbidden unless current_membership.admin?

    membership = current_organization.memberships.active.find(params[:id])
    role = params[:role]
    owners = current_organization.memberships.active.where(role: "owner").count
    if !Membership::ROLES.include?(role)
      redirect_to organization_members_path(current_organization.slug), alert: "Unknown role."
    elsif membership.role == "owner" && role != "owner" && owners <= 1
      redirect_to organization_members_path(current_organization.slug),
                  alert: "The last owner cannot be demoted."
    else
      membership.update!(role: role)
      current_organization.record_activity!(current_user, "member.role_changed",
                                            "#{membership.user.email} is now #{role}")
      redirect_to organization_members_path(current_organization.slug)
    end
  end

  def destroy
    return head :forbidden unless current_membership.admin?

    membership = current_organization.memberships.active.find(params[:id])
    owners = current_organization.memberships.active.where(role: "owner").count
    if membership.role == "owner" && owners <= 1
      redirect_to organization_members_path(current_organization.slug),
                  alert: "The last owner cannot be removed."
    else
      membership.update!(status: "removed")
      current_organization.record_activity!(current_user, "member.removed",
                                            "Removed #{membership.user.email}")
      redirect_to organization_members_path(current_organization.slug)
    end
  end
end
