class SearchesController < ApplicationController
  before_action :require_login, :require_member

  def show
    @query = params[:q].to_s.strip
    if @query.present?
      like = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
      @companies = current_organization.companies.where("name LIKE ?", like).limit(20)
      @contacts = current_organization.contacts.where(
        "full_name LIKE ? OR email LIKE ?", like, like
      ).limit(20)
      @deals = current_organization.deals.where("title LIKE ?", like).limit(20)
    end
  end
end
