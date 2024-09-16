require "rubygems"
require "twilio-ruby"

class Api::V1::VideoCallController < Api::V1::ApiController
  before_action :authorize_user
  before_action :set_twilio_credentials

  def video_call_history
    all_calls = fetch_call_history("Video Call", "Group Video Call")
    render json: { history: format_call_history(all_calls) }
  end

  def all_call_history
    all_calls = fetch_call_history(nil, nil)
    render json: { history: format_call_history(all_calls) }
  end

  def recent_call_history
    all_calls = fetch_call_history(nil, nil, 3)
    render json: { history: format_call_history(all_calls) }
  end

  def remove_recent_call_history
    history = current_user.rooms.order(created_at: :desc).limit(10)
    if history.present?
      history.destroy_all
      render json: { message: "Recent Call log deleted" }
    else
      render json: { message: "Recent Call log is not present" }, status: :unauthorized
    end
  end

  def remove_all_call_history
    if current_user.rooms.exists?
      current_user.rooms.destroy_all
      render json: { message: "Call logs cleared!" }
    else
      render json: { message: "Call logs already empty" }, status: :unauthorized
    end
  end

  def remove_any_call_log
    room = Room.find_by(id: params[:room_id])
    group_room = GroupRoom.find_by(id: params[:room_id])

    if room
      delete_room_log(room)
    elsif group_room
      delete_group_room_log(group_room)
    else
      render json: { message: "Call log is not present" }, status: :unauthorized
    end
  end

  def remove_video_call_log
    room = current_user.rooms.find_by(id: params[:id], room_mode: "Video Call")
    if room
      room.delete
      render json: { message: "Call log deleted" }
    else
      render json: { message: "Call log is not present" }, status: :unauthorized
    end
  end

  def videocall
    @room = Room.find_by(uname: params[:room_uname])
    begin
      if @room
        join_existing_room(@room)
      else
        create_new_room
      end
    rescue => e
      render json: { message: e.message }, status: :unauthorized
    end
  end

  def destroy_room
    begin
      @room = Room.find_by(uname: params[:room_uname])
      twilio_room = fetch_twilio_room(@room.uname)

      if twilio_room.status == "completed"
        @room.update(room_status: "completed")
        render json: { message: "Room already destroyed" }, status: :unauthorized
      else
        complete_room(@room, twilio_room)
      end
    rescue => e
      render json: { message: e.message }, status: :unauthorized
    end
  end

  private

  def fetch_call_history(room_mode, group_room_mode, limit = nil)
    user_rooms = current_user.rooms.where(deleted_by_user: false, room_mode: room_mode).order(created_at: :desc)
    receiver_rooms = Room.where(receiver_id: current_user, deleted_by_receiver: false, room_mode: room_mode).order(created_at: :desc)
    group_rooms = GroupRoom.joins(:participants).where(participants: { user_id: current_user, deleted: false }, room_mode: group_room_mode).order(created_at: :desc)

    if limit
      user_rooms = user_rooms.limit(limit)
      receiver_rooms = receiver_rooms.limit(limit)
      group_rooms = group_rooms.limit(limit)
    end

    (user_rooms + receiver_rooms + group_rooms).sort_by(&:created_at).reverse
  end

  def format_call_history(calls)
    calls.map { |call| call_history_object(call) }
  end

  def call_history_object(call)
    if call.receiver_id
      format_direct_call(call)
    else
      format_group_call(call)
    end
  end

  def format_direct_call(call)
    receiver = (call.receiver == current_user ? call.user : call.receiver)
    contact = find_contact(call.user, call.receiver)
    {
      room_id: call.id,
      room_mode: call.room_mode,
      created_at: call.created_at,
      participant_name: receiver.name,
      profile_status: receiver.profile_status || "",
      receiver_image: receiver.image.attached? ? url_for(receiver.image) : "",
      call_status: call.user == current_user ? "Outgoing" : "Incoming",
      contacts: contact,
    }
  end

  def format_group_call(call)
    group = call.group
    {
      room_id: call.id,
      room_mode: call.room_mode,
      created_at: call.created_at,
      group_id: group.id,
      profile_status: group.status || "",
      participant_name: group.name,
      receiver_image: group.contacts.limit(2).map { |contact| contact.image.attached? ? url_for(contact.image) : "" },
      contacts: group.contacts.map { |contact| format_contact(contact) },
    }
  end

  def format_contact(contact)
    {
      contact_id: contact.id,
      image_url: contact.image.attached? ? url_for(contact.image) : "",
      blocked: contact.blocked?,
      name: contact.name,
    }
  end

  def find_contact(user, receiver)
    contact = Contact.find_by(user_id: user.id, companion_id: receiver.id) || Contact.find_by(user_id: receiver.id, companion_id: user.id)
    if contact
      {
        contact_id: contact.id,
        user_id: contact.companion.id,
        image_url: contact.image.attached? ? url_for(contact.image) : "",
        blocked: contact.blocked?,
        name: contact.name,
        country: contact.companion.country,
      }
    end
  end

  def delete_room_log(room)
    if room.user == current_user
      room.update(deleted_by_user: true)
    else
      room.update(deleted_by_receiver: true)
    end
    render json: { message: "Call log deleted" }
  end

  def delete_group_room_log(group_room)
    participant = group_room.participants.find_by(user_id: current_user)
    participant.update(deleted: true) if participant
    render json: { message: "Call log deleted" }
  end

  def join_existing_room(room)
    @client = Twilio::REST::Client.new(@account_sid, @auth_token)
    twilio_room = @client.video.v1.rooms(room.uname).fetch
    token_response = generate_authentication_token(twilio_room)

    send_notification(room, "Calling", "is calling", "Accept Call")

    if token_response.success
      render_room_data(twilio_room, token_response)
    end
  end

  def create_new_room
    @client = Twilio::REST::Client.new(@account_sid, @auth_token)
    twilio_room = @client.video.v1.rooms.create(type: "group")
    token_response = generate_authentication_token(twilio_room)
    receiver = find_receiver(params[:contact_id])

    return render json: { message: "Receiver not found" }, status: :unauthorized unless receiver
    return render json: { message: "Receiver is blocked" }, status: :unauthorized if receiver.blocked?

    @room = Room.create(
      uname: twilio_room.unique_name,
      room_type: twilio_room.type,
      room_status: "in-progress",
      room_mode: "Video Call",
      user_id: current_user.id,
      receiver_id: receiver.id
    )

    send_notification(@room, "Calling", "is calling", "Video Call")

    if token_response.success
      render_room_data(twilio_room, token_response)
    end
  end

  def send_notification(room, title, message_suffix, notification_type)
    notification = Notification.create(
      title: title,
      descrption: "#{current_user.name} #{message_suffix}.",
      notification_date: Time.now,
      notification_type: notification_type,
      user_id: room.receiver_id
    )
    fcm_push_notification(notification, room)
  end

  def render_room_data(room, token_response)
    render json: {
      token_user: token_response.token_user,
      room_sid: room.sid,
      audio_only: room.audio_only,
      status: room.status,
      created_date: room.date_created,
      update_at: room.date_updated,
      account_sid: room.account_sid,
      enable_turn: room.enable_turn,
      unique_name: room.unique_name,
      status_callback: room.status_callback,
      status_callback_method: room.status_callback_method,
      room_type: room.type,
      max_participants: room.max_participants,
      end_time: room.end_time,
      duration: room.duration,
      url: room.url,
      links: room.links,
      user: current_user,
      receiver: room.receiver
    }
  end

  def complete_room(room, twilio_room)
    @client.video.v1.rooms(twilio_room.sid).update(status: "completed")
    room.update(room_status: "completed")
    send_notification(room, "End Call", "is ending call", "Reject Call")
    render json: { message: "Room destroyed" }
  end

  def fetch_twilio_room(room_uname)
    @client.video.v1.rooms(room_uname).fetch
  end

  def generate_authentication_token(room)
    video_grant = Twilio::JWT::AccessToken::VideoGrant.new
    video_grant.room = room.unique_name

    token_user = Twilio::JWT::AccessToken.new(
      ENV["TWILIO_ACCOUNT_SID_PROD"],
      ENV["TWILIO_API_SID"],
      ENV["TWILIO_API_SECRETS"],
      [video_grant],
      identity: current_user.email
    )

    OpenStruct.new(success: true, token_user: token_user.to_jwt)
  end

  def set_twilio_credentials
    @account_sid = ENV["TWILIO_ACCOUNT_SID_PROD"]
    @auth_token = ENV["TWILIO_AUTH_TOKEN_PROD"]
  end

  def fcm_push_notification(notification, room)
    fcm_client = FCM.new(ENV["FIREBASE_SERVER_KEY"])
    receiver_user = User.find_by(id: notification.user_id)
    options = build_fcm_options(notification, room, receiver_user)
    registration_ids = receiver_user.mobile_devices.pluck(:token)

    registration_ids.each do |registration_id|
      fcm_client.send(registration_id, options)
    end
  end

  def build_fcm_options(notification, room, receiver_user)
    {
      priority: "high",
      data: {
        message: notification.descrption,
        type: notification.notification_type,
        receiver: receiver_user,
        receiver_image: url_for(receiver_user.image) if receiver_user.image.attached?,
        room_name: room.uname,
        user: current_user,
        user_image: url_for(current_user.image) if current_user.image.attached?
      },
      notification: {
        body: notification.descrption,
        title: notification.title,
        sound: "default"
      }
    }
  end

  def find_receiver(contact_id)
    contact = current_user.contacts.find_by(id: contact_id)
    contact ? User.find_by(id: contact.companion_id) : nil
  end
end
