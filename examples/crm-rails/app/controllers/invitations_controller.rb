class InvitationsController < ApplicationController
  before_action :require_login
  before_action :require_member, only: [:create, :revoke]

  def create
    return head :forbidden unless current_membership.admin?

    invitation = current_organization.invitations.create!(
      email: params[:email].to_s.strip.downcase,
      role: Membership::ROLES.include?(params[:role]) ? params[:role] : "member",
      invited_by: current_user
    )
    current_organization.record_activity!(current_user, "member.invited",
                                          "Invited #{invitation.email} as #{invitation.role}")
    redirect_to organization_members_path(current_organization.slug),
                notice: "Share this single-use link: #{accept_invitation_url(invitation.token)}"
  end

  def revoke
    return head :forbidden unless current_membership.admin?

    invitation = current_organization.invitations.find(params[:id])
    invitation.update!(revoked_at: Time.current) if invitation.pending?
    redirect_to organization_members_path(current_organization.slug)
  end

  def show
    @invitation = Invitation.find_by!(token: params[:token])
  end

  def accept
    invitation = Invitation.find_by!(token: params[:token])
    begin
      invitation.accept!(current_user)
    rescue ArgumentError => error
      return redirect_to root_path, alert: error.message
    end
    invitation.organization.record_activity!(current_user, "member.joined",
                                             "#{current_user.email} joined as #{invitation.role}")
    redirect_to organization_path(invitation.organization.slug)
  end
end
