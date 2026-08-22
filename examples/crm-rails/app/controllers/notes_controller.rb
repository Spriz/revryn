class NotesController < ApplicationController
  before_action :require_login, :require_member

  NOTABLES = { "Company" => Company, "Contact" => Contact, "Deal" => Deal }.freeze

  def create
    klass = NOTABLES.fetch(params[:notable_type]) { return head :unprocessable_entity }
    notable = klass.where(organization: current_organization).find(params[:notable_id])
    current_organization && Note.create!(
      organization: current_organization, author: current_user,
      notable: notable, body: params[:body].to_s.strip
    )
    current_organization.record_activity!(current_user, "note.added",
                                          "Noted on #{params[:notable_type]} ##{notable.id}")
    redirect_back fallback_location: organization_path(current_organization.slug)
  end
end
