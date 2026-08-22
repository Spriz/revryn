class Membership < ApplicationRecord
  ROLES = %w[owner admin member].freeze

  belongs_to :organization
  belongs_to :user

  validates :role, inclusion: { in: ROLES }
  scope :active, -> { where(status: "active") }

  def admin? = %w[owner admin].include?(role)

  after_create_commit :raise_committed_seats
  after_commit :sync_billing_seats

  private

  # Seat increases take effect immediately (BC-US-150): the committed
  # floor rises with every add so later decreases wait for period end.
  def raise_committed_seats
    active = organization.memberships.active.count
    organization.update!(committed_seats: [organization.committed_seats, active].max)
  end

  # Integrated mode: seat changes flow to Billing Core; failures log
  # loudly and never break the product action (idempotent re-sync).
  def sync_billing_seats
    return unless BillingCore::Integration.enabled?

    BillingCore::Provisioning.sync_seats(organization)
  rescue BillingCore::Error => error
    Rails.logger.error("billing seat sync failed for #{organization.slug}: #{error.message}")
  end
end
