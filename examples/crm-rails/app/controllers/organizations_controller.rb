class OrganizationsController < ApplicationController
  before_action :require_login

  def index
    @memberships = current_user.memberships.active.includes(:organization)
  end

  def new; end

  def create
    name = params[:name].to_s.strip
    return redirect_to(new_organization_path, alert: "A name is required.") if name.blank?

    slug = base = name.parameterize.presence || "org"
    n = 2
    while Organization.exists?(slug: slug)
      slug = "#{base}-#{n}"
      n += 1
    end

    organization = nil
    ActiveRecord::Base.transaction do
      organization = Organization.create!(name: name, slug: slug)
      organization.memberships.create!(user: current_user, role: "owner")
      pipeline = organization.pipelines.create!(name: "Sales")
      %w[Lead Qualified Proposal Won].each_with_index do |stage, position|
        pipeline.stages.create!(name: stage, position: position)
      end
      organization.record_activity!(current_user, "org.created", "Created organization")
    end
    redirect_to organization_path(organization.slug)
  end

  def show
    @organization = current_organization
    return head :forbidden unless current_membership

    @pipelines = @organization.pipelines.includes(:stages)
    @recent = @organization.activities.limit(8)
  end
end
