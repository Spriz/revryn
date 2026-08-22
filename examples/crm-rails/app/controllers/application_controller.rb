class ApplicationController < ActionController::Base
  allow_browser versions: :modern
  helper_method :current_user, :current_membership

  private

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  def require_login
    redirect_to login_path, alert: "Sign in first." unless current_user
  end

  def current_organization
    @current_organization ||= Organization.find_by!(slug: params[:organization_slug] || params[:slug])
  end

  def current_membership
    return nil unless current_user && @current_organization

    @current_membership ||= @current_organization.memberships.active.find_by(user: current_user)
  end

  def require_member
    current_organization
    head :forbidden unless current_membership
  end

  def require_admin
    require_member
    head :forbidden unless performed? == false && current_membership&.admin?
  end
end
