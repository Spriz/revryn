class Contact < ApplicationRecord
  belongs_to :organization
  belongs_to :company, optional: true
  has_many :notes, as: :notable, dependent: :destroy

  validates :full_name, presence: true

  def self.to_csv(contacts)
    CSV.generate(headers: true) do |csv|
      csv << %w[full_name email phone title company]
      contacts.find_each do |contact|
        csv << [contact.full_name, contact.email, contact.phone, contact.title,
                contact.company&.name]
      end
    end
  end

  # Import is idempotent per (organization, email) and creates missing
  # companies by name.
  def self.import_csv(organization, io)
    imported = 0
    CSV.parse(io.read, headers: true) do |row|
      email = row["email"].to_s.strip.downcase
      company =
        if row["company"].present?
          organization.companies.find_or_create_by!(name: row["company"].strip)
        end
      contact = email.present? ? organization.contacts.find_or_initialize_by(email: email) : organization.contacts.new
      contact.assign_attributes(
        full_name: row["full_name"].to_s.strip.presence || email,
        phone: row["phone"].to_s,
        title: row["title"].to_s,
        company: company
      )
      contact.save!
      imported += 1
    end
    imported
  end
end
