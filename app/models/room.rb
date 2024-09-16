class Room < ApplicationRecord
  belongs_to :user
  belongs_to :receiver, class_name: 'User'
  has_many :notifications, dependent: :destroy

  scope :video_calls, -> { where(room_mode: 'Video Call') }
  scope :group_video_calls, -> { where(room_mode: 'Group Video Call') }
end
