class ContactsController < ApplicationController
  before_action :require_login, :require_member

  def index
    @contacts = current_organization.contacts.includes(:company).order(:full_name)
    respond_to do |format|
      format.html
      format.csv do
        send_data Contact.to_csv(@contacts), filename: "contacts.csv"
      end
    end
  end

  def create
    contact = current_organization.contacts.create(contact_params)
    if contact.persisted?
      current_organization.record_activity!(current_user, "contact.created",
                                            "Added contact #{contact.full_name}")
    end
    redirect_to organization_contacts_path(current_organization.slug)
  end

  def show
    @contact = current_organization.contacts.find(params[:id])
    @notes = @contact.notes.includes(:author).order(created_at: :desc)
  end

  def import
    if params[:file].blank?
      return redirect_to organization_contacts_path(current_organization.slug),
                         alert: "Choose a CSV file first."
    end

    imported = Contact.import_csv(current_organization, params[:file])
    current_organization.record_activity!(current_user, "contact.imported",
                                          "Imported #{imported} contacts from CSV")
    redirect_to organization_contacts_path(current_organization.slug),
                notice: "Imported #{imported} contacts."
  end

  private

  def contact_params
    permitted = params.permit(:full_name, :email, :phone, :title, :company_id)
    if permitted[:company_id].present?
      permitted[:company_id] = current_organization.companies.find(permitted[:company_id]).id
    end
    permitted
  end
end
