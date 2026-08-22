class Invitation < ApplicationRecord
  belongs_to :organization
  belongs_to :invited_by, class_name: "User", optional: true

  before_validation { self.token ||= SecureRandom.urlsafe_base64(32) }
  validates :email, presence: true
  validates :role, inclusion: { in: Membership::ROLES }

  def pending? = accepted_at.nil? && revoked_at.nil?

  # Single-use and email-bound, like the platform it showcases.
  def accept!(user)
    raise ArgumentError, "invitation is not pending" unless pending?
    raise ArgumentError, "invitation was issued to a different email" unless user.email == email.strip.downcase

    membership = organization.memberships.create_with(role: role, status: "active")
                             .find_or_create_by!(user: user)
    membership.update!(role: role, status: "active")
    update!(accepted_at: Time.current)
    membership
  end
end
