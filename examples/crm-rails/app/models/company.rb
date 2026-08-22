class Company < ApplicationRecord
  belongs_to :organization
  has_many :contacts, dependent: :nullify
  has_many :deals, dependent: :nullify
  has_many :notes, as: :notable, dependent: :destroy

  validates :name, presence: true
end
