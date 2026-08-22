class Deal < ApplicationRecord
  STATUSES = %w[open won lost].freeze

  belongs_to :organization
  belongs_to :company, optional: true
  belongs_to :contact, optional: true
  belongs_to :stage
  belongs_to :owner, class_name: "User", optional: true
  has_many :notes, as: :notable, dependent: :destroy

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :amount_ore, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def amount_display
    format("%.2f DKK", Rational(amount_ore, 100)).tr(".", ",")
  end
end
