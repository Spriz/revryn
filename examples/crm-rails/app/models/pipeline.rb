class Pipeline < ApplicationRecord
  belongs_to :organization
  has_many :stages, -> { order(:position, :id) }, dependent: :destroy
  has_many :deals, through: :stages

  validates :name, presence: true
end
