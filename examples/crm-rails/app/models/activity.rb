class Activity < ApplicationRecord
  belongs_to :organization
  belongs_to :actor, class_name: "User", optional: true

  default_scope { order(created_at: :desc) }
end
