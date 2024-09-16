class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :room, optional: true
  belongs_to :group_room, optional: true

  scope :recent, -> { order(notification_date: :desc).limit(10) }
end
