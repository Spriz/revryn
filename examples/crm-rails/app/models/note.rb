class Note < ApplicationRecord
  belongs_to :organization
  belongs_to :author, class_name: "User"
  belongs_to :notable, polymorphic: true

  validates :body, presence: true
end
