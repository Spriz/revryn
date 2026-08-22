class ActivitiesController < ApplicationController
  before_action :require_login, :require_member

  def index
    @activities = current_organization.activities.includes(:actor).limit(200)
  end
end
