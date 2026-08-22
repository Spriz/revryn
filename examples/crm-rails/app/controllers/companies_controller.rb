class CompaniesController < ApplicationController
  before_action :require_login, :require_member

  def index
    @companies = current_organization.companies.order(:name)
  end

  def create
    company = current_organization.companies.create(company_params)
    if company.persisted?
      current_organization.record_activity!(current_user, "company.created",
                                            "Added company #{company.name}")
    end
    redirect_to organization_companies_path(current_organization.slug)
  end

  def show
    @company = current_organization.companies.find(params[:id])
    @contacts = @company.contacts.order(:full_name)
    @deals = @company.deals.includes(:stage)
    @notes = @company.notes.includes(:author).order(created_at: :desc)
  end

  private

  def company_params
    params.permit(:name, :domain, :city)
  end
end
