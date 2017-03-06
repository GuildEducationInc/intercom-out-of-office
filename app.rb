require 'sinatra'
require 'json'
require 'active_support/time'
require 'intercom'
require 'nokogiri'
require 'dotenv'
Dotenv.load

INTERNAL_NOTE_MESSAGE = "Out of office autoresponder: "
DEBUG = ENV["DEBUG"] || nil

post '/' do
  request.body.rewind
  payload_body = request.body.read
  if DEBUG then
    puts "==============================================================="
    puts payload_body
    puts "==============================================================="
  end
  verify_signature(payload_body)
  response = JSON.parse(payload_body)
  if DEBUG then
    puts "Topic Recieved: #{response['topic']}"
  end
  if is_supported_topic(response['topic']) then
    process_out_of_office_response(response) unless is_office_hours
  end
end

def init_intercom
  if @intercom.nil? then
    app_id = ENV["APP_ID"]
    api_key = ENV["API_KEY"]
    @intercom = Intercom::Client.new(app_id: app_id, api_key: api_key)
  end
end

def is_supported_topic(topic)
  topic.index("conversation.user.created") or topic.index("conversation.user.replied")
end

def process_out_of_office_response(response)
  if DEBUG then
    puts "Process out of office response....."
  end

  begin
    conversation_id = response["data"]["item"]["id"]
  rescue
    puts "Could not retrieve conversation ID. Abort abort"
    return
  end

  if DEBUG then
    puts "Conversation: #{conversation_id}"
  end
  send_out_of_office_message(conversation_id) unless already_sent_message_in_past_24_hours(conversation_id)
end

def send_out_of_office_message (conversation_id)
  if DEBUG then
    puts "Sending out of office message!"
  end
  admin_id = ENV["bot_admin_id"]
  message = ENV["message"] || "We are not available at the moment, we'll get back to you as soon as possible"
  init_intercom
  @intercom.conversations.reply(:id => conversation_id, :type => 'admin', :admin_id => admin_id, :message_type => 'comment', :body => message)
  @intercom.conversations.reply(:id => conversation_id, :type => 'admin', :admin_id => admin_id, :message_type => 'note', :body => "#{INTERNAL_NOTE_MESSAGE} #{Time.now.to_i}")
end

def already_sent_message_in_past_24_hours (conversation_id)
  init_intercom
  conversation = @intercom.conversations.find(:id => conversation_id)

  conversation.conversation_parts
    .select{|c| c.part_type == "note"}
    .each{|c|
      if(c.body.index(INTERNAL_NOTE_MESSAGE)) then
        str = c.body
        doc = Nokogiri::HTML(str)
        last_note_timestamp = doc.xpath("//text()").to_s.split(" ").last
        begin
          did_post_in_last_24_hours = Time.now.to_i - last_note_timestamp.to_i < 24 * 60 * 60
          if DEBUG then
            puts "did_post_in_last_24_hours #{did_post_in_last_24_hours}"
          end
          return true if did_post_in_last_24_hours
        rescue
        end
      end
    }
  return false
end

def is_office_hours
  timezone_string = ENV["timezone"]
  hours_hash = create_hours_hash
  current_time = Time.now
  timezone = nil

  if not timezone_string.nil? and not timezone_string.empty?
    begin
      timezone = ActiveSupport::TimeZone[timezone_string]
    rescue
      puts "Invalid timezone: #{timezone_string}"
    end
  end

  if timezone.nil?
    time = current_time.hour * 100 + current_time.min
    day = current_time.strftime("%A").downcase
  else
    current_time_in_timezone = timezone.at(current_time)
    time = current_time_in_timezone.hour * 100 + current_time_in_timezone.min
    day = current_time.strftime("%A").downcase
  end

  todays_start = hours_hash[day][:time_start] || "900"
  todays_end = hours_hash[day][:time_stop] || "2000"

  if DEBUG
    puts "Current time: #{current_time}"
    puts "Timezone: #{timezone_string}"
    puts "Calculated Time: #{time}"
    puts "     Start time: #{todays_start.to_i}"
    puts "      Stop time: #{todays_end.to_i}"
  end

  is_office_hours = ((time >= todays_start.to_i && time <= todays_end.to_i))

  if DEBUG then
    puts "Office hours: #{is_office_hours} based on calculations"
  end

  is_office_hours
end

def create_hours_hash
  {
    "monday" => {time_start: ENV["mon_time_start"], time_stop: ENV["mon_time_stop"]},
    "tuesday" => {time_start: ENV["tues_time_start"], time_stop: ENV["tues_time_stop"]},
    "wednesday" => {time_start: ENV["wed_time_start"], time_stop: ENV["wed_time_stop"]},
    "thursday" => {time_start: ENV["thurs_time_start"], time_stop: ENV["thurs_time_stop"]},
    "friday" => {time_start: ENV["fri_time_start"], time_stop: ENV["fri_time_stop"]},
    "saturday" => {time_start: ENV["sat_time_start"], time_stop: ENV["sat_time_stop"]},
    "sunday" => {time_start: ENV["sun_time_start"], time_stop: ENV["sun_time_stop"]},
  }
end

def verify_signature(payload_body)
  secret = ENV["secret"]
  expected = request.env['HTTP_X_HUB_SIGNATURE']

  if secret.nil? || secret.empty? then
    puts "No secret specified so accept all data"
  elsif expected.nil? || expected.empty? then
    puts "Not signed. Not calculating"
  else

    signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), secret, payload_body)
    puts "Expected  : #{expected}"
    puts "Calculated: #{signature}"
    if Rack::Utils.secure_compare(signature, expected) then
      puts "   Match"
    else
      puts "   MISMATCH!!!!!!!"
      return halt 500, "Signatures didn't match!"
    end
  end
end
