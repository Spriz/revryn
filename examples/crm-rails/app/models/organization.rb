class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :invitations, dependent: :destroy
  has_many :companies, dependent: :destroy
  has_many :contacts, dependent: :destroy
  has_many :pipelines, dependent: :destroy
  has_many :deals, dependent: :destroy
  has_many :activities, dependent: :destroy

  validates :name, presence: true
  validates :billing_interval, inclusion: { in: %w[monthly annual] }
  validates :seat_decrease_timing, inclusion: { in: %w[immediate period_end] }

  def role_of(user)
    memberships.active.find_by(user: user)&.role
  end

  def active_seats = memberships.active.count

  # BC-US-150: increases bill immediately; decreases follow configured
  # timing. The committed floor models period_end timing locally.
  def billable_seats
    return active_seats if seat_decrease_timing == "immediate"

    [active_seats, committed_seats].max
  end

  def record_activity!(actor, verb, summary)
    activities.create!(actor: actor, verb: verb, summary: summary)
  end
end
