# frozen_string_literal: true

# name: Discourse Matrix Bridge
# about: Bridge Discourse Chat channels with Matrix Synapse rooms
# version: 0.1
# authors: ChatGPT
# url: https://example.com/discourse-matrix-bridge

enabled_site_setting :matrix_bridge_enabled

require "net/http"
require "uri"
require "json"
require "cgi"
require "securerandom"

module ::DiscourseMatrix
  PLUGIN_NAME = "discourse-matrix-bridge"
end

after_initialize do
  if defined?(::Chat)
    module ::DiscourseMatrix
      class Bridge
        class << self
          def mappings
            raw = SiteSetting.matrix_bridge_mappings.presence || "[]"
            JSON.parse(raw) rescue []
          end

          def find_mapping_for_channel_id(channel_id)
            mappings.find { |m| m["chat_channel_id"].to_i == channel_id.to_i }
          end

          def find_mapping_for_room_id(room_id)
            mappings.find { |m| m["matrix_room_id"] == room_id }
          end

          def matrix_client
            # For debugging with a Flask server, homeserver is hardcoded here.
            # Flask app should listen on 104.218.100.58:5006.
            @matrix_client ||= DiscourseMatrix::MatrixClient.new(
              homeserver: "http://104.218.100.58:5006",
              access_token: SiteSetting.matrix_bot_access_token,
              extra_header_name: SiteSetting.matrix_extra_header_name,
              extra_header_value: SiteSetting.matrix_extra_header_value,
            )
          end

          def bridge_user
            @bridge_user ||= User.find_by(username: SiteSetting.matrix_bridge_discourse_username)
          end

          def enqueue_matrix_send(message, channel, user)
            return if !SiteSetting.matrix_bridge_enabled

            mapping = find_mapping_for_channel_id(channel.id)
            return if mapping.blank?

            # Avoid echo-loop: do not send messages that were posted by the bridge user itself
            return if user&.id.present? && bridge_user&.id.present? && user.id == bridge_user.id

            Jobs.enqueue(
              :matrix_send_message,
              matrix_room_id: mapping["matrix_room_id"],
              message_id: message.id,
            )
          end
        end
      end

      class MatrixClient
        def initialize(homeserver:, access_token:, extra_header_name: nil, extra_header_value: nil)
          @homeserver = (homeserver || "").sub(%r{/*$}, "")
          @access_token = access_token
          @extra_header_name = extra_header_name.presence
          @extra_header_value = extra_header_value.presence
        end

        def send_text(room_id:, body:, txn_id: nil)
          txn_id ||= "discourse-#{SecureRandom.uuid}"
          path = "/_matrix/client/v3/rooms/#{CGI.escape(room_id)}/send/m.room.message/#{txn_id}"
          payload = { msgtype: "m.text", body: body }
          request(:put, path, payload)
        end

        def sync(since: nil, timeout_ms: 30_000)
          params = { timeout: timeout_ms }
          params[:since] = since if since
          path = "/_matrix/client/v3/sync?#{URI.encode_www_form(params)}"
          request(:get, path)
        end

        private

        def request(method, path, body = nil)
          return {} if @homeserver.blank?

          uri = URI.parse("#{@homeserver}#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"

          req_class =
            case method
            when :get
              Net::HTTP::Get
            when :put
              Net::HTTP::Put
            when :post
              Net::HTTP::Post
            else
              raise ArgumentError, "Unsupported HTTP method: #{method}"
            end

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 10
          http.read_timeout = 10
          
          req = req_class.new(uri.request_uri)
          req["Authorization"] = "Bearer #{@access_token}" if @access_token.present?

          if @extra_header_name && @extra_header_value
            req[@extra_header_name] = @extra_header_value
          end

          if body
            req["Content-Type"] = "application/json"
            req.body = JSON.dump(body)
          end

          response = http.request(req)

          if response.code.to_i >= 400
            Rails.logger.warn(
              "[discourse-matrix] #{method.to_s.upcase} #{uri} failed: #{response.code} #{response.body}",
            )
          end

          JSON.parse(response.body) rescue {}
        rescue => e
          Rails.logger.warn("[discourse-matrix] request error: #{e.class} #{e.message}")
          {}
        end
      end
    end

    module ::Jobs
      class MatrixSendMessage < ::Jobs::Base
        def execute(args)
          return if !SiteSetting.matrix_bridge_enabled

          message = ::Chat::Message.find_by(id: args[:message_id])
          return if message.blank?

          # Different Discourse chat versions expose either `channel` or `chat_channel`
          channel =
            if message.respond_to?(:channel)
              message.channel
            else
              message.chat_channel
            end

          return if channel.blank?

          user = message.user
          bridge_user = ::DiscourseMatrix::Bridge.bridge_user
          return if bridge_user.blank?

          mapping = ::DiscourseMatrix::Bridge.find_mapping_for_channel_id(channel.id)
          return if mapping.blank?

          prefix = "[#{user.username}]: "
          body = prefix + message.message.to_s

          client = ::DiscourseMatrix::Bridge.matrix_client
          client.send_text(room_id: mapping["matrix_room_id"], body: body)
        end
      end
    end

    module ::Jobs
      class MatrixSync < ::Jobs::Scheduled
        every 1.minute

        def execute(args)
          return if !SiteSetting.matrix_bridge_enabled

          # Loop for ~55 seconds to keep the bridge active between 1-minute job schedules
          start_time = Time.now
          while Time.now - start_time < 55
            begin
                client = ::DiscourseMatrix::Bridge.matrix_client
                since = PluginStore.get(::DiscourseMatrix::PLUGIN_NAME, "matrix_sync_since")
                
                # User requested 5s sync time
                resp = client.sync(since: since, timeout_ms: 5000)

                next_batch = resp["next_batch"]
                rooms = resp.dig("rooms", "join") || {}

                rooms.each do |room_id, room_data|
                    timeline = room_data.dig("timeline", "events") || []
                    timeline.each do |event|
                    handle_event(room_id, event)
                    end
                end

                if next_batch
                    PluginStore.set(::DiscourseMatrix::PLUGIN_NAME, "matrix_sync_since", next_batch)
                end
            rescue => e
                Rails.logger.warn("[discourse-matrix] Sync loop error: #{e.message}")
                sleep 5 # Backoff slightly on error
            end
            
            # Tiny sleep to verify we don't hot-loop if sync returns instantly
            sleep 0.5
          end
        end

        private

        def handle_event(room_id, event)
          return unless ["m.room.message", "m.sticker"].include?(event["type"])

          content = event["content"] || {}
          msgtype = content["msgtype"]
          return unless ["m.text", "m.image", "m.file", "m.video"].include?(msgtype)

          body = content["body"].to_s
          
          # Handle Media (Images/GIFs)
          if msgtype == "m.image" || msgtype == "m.file" || msgtype == "m.video"
            mxc_url = content["url"]
            if mxc_url =~ /^mxc:\/\/(.+)\/(.+)$/
              server_name = $1
              media_id = $2
              # Construct public HTTPS URL for the media
              # We use the server_name from the MXC URI assuming it serves HTTPS
              http_url = "https://#{server_name}/_matrix/media/v3/download/#{server_name}/#{media_id}"
              
              # Use Markdown format for image preview
              body = "![#{body}](#{http_url})" 
              
              # If it's a file/video that might not onebox well, we can just append the link
              if msgtype != "m.image"
                 body = "[#{content['body']}](#{http_url})"
              end
            end
          end
          
          sender = event["sender"] # e.g. "@alice:example.com"
          event_id = event["event_id"]

          Rails.logger.info "[discourse-matrix] handling Matrix event #{event_id} from #{sender} in #{room_id}: #{body.inspect}"

          bridge_mx_userid = SiteSetting.matrix_bot_user_id.presence
          Rails.logger.info "[discourse-matrix] Processing event: sender=#{sender}, bridge_bot_id=#{bridge_mx_userid}"
          
          # Avoid echo loop: ignore messages sent by the Matrix bot user itself
          if bridge_mx_userid && sender.strip == bridge_mx_userid.strip
            Rails.logger.info "[discourse-matrix] skipping event #{event_id} because sender is the bot user #{bridge_mx_userid}"
            return
          end

          mapping = ::DiscourseMatrix::Bridge.find_mapping_for_room_id(room_id)
          if mapping.blank?
            Rails.logger.info "[discourse-matrix] no mapping found for room #{room_id}; skipping event #{event_id}"
            return
          end
          Rails.logger.info "[discourse-matrix] Found mapping: #{mapping.inspect}"

          channel = ::Chat::Channel.find_by(id: mapping["chat_channel_id"].to_i)
          if channel.blank?
            Rails.logger.warn "[discourse-matrix] mapping found for room #{room_id} but chat channel #{mapping["chat_channel_id"]} is missing"
            return
          end
          Rails.logger.info "[discourse-matrix] Found channel: #{channel.id}"

          bridge_user = ::DiscourseMatrix::Bridge.bridge_user
          if bridge_user.blank?
            Rails.logger.warn "[discourse-matrix] bridge user not found; cannot create chat message for event #{event_id}"
            return
          end
          Rails.logger.info "[discourse-matrix] Found bridge user: #{bridge_user.username}"

          # Wrap the sender in backticks to prevent Discourse from parsing it as a mention (code block style)
          full_body = "[`#{sender}`]: #{body}"

          # Ensure bridge user is a member of the channel
          # Category channels (public) are handled differently than DM/Private channels
          is_category_channel = channel.is_a?(::Chat::CategoryChannel)
          
          if !is_category_channel && !channel.memberships.exists?(user_id: bridge_user.id)
             ::Chat::Publisher.publish_new_channel_membership(
               channel,
               channel.add(bridge_user),
             )
          elsif is_category_channel
             # Category channels usually don't have explicit join/leave logic for 'membership'
             # in the same way, or it's handled via allowing the user to create messages.
             # We just ensure the user follows the channel.
             if defined?(::Chat::Membership) && !::Chat::Membership.exists?(user_id: bridge_user.id, chat_channel_id: channel.id)
               ::Chat::Membership.create(user_id: bridge_user.id, chat_channel_id: channel.id, following: true)
             end
          end

          creator =
            ::Chat::CreateMessage.call(
              guardian: bridge_user.guardian,
              params: {
                chat_channel_id: channel.id,
                message: full_body,
              },
            )

          if creator.failure?
            Rails.logger.warn "[discourse-matrix] failed to create chat message from Matrix event #{event_id}: #{creator.inspect_steps}"
          else
            Rails.logger.info "[discourse-matrix] created chat message from Matrix event #{event_id} in channel #{channel.id} as user #{bridge_user.username}"
          end
        rescue => e
          Rails.logger.warn "[discourse-matrix] error handling Matrix event: #{e.class} #{e.message}"
        end
      end
    end

    # Discourse Chat -> Matrix: hook into chat message creation
    on(:chat_message_created) do |message, channel, user|
      ::DiscourseMatrix::Bridge.enqueue_matrix_send(message, channel, user)
    end
  else
    Rails.logger.warn "[discourse-matrix] Chat plugin not loaded; Matrix bridge will be inactive."
  end
end
