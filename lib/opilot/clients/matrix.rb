require "net/http"
require "uri"
require "json"

module OPilot
  module Clients
    # The Matrix Client-Server API, as far as the Matrix chat interface needs it,
    # over Clients::HTTP with a Bearer header. The token never goes in a URL.
    class Matrix
      Error = Class.new(StandardError)

      API = "/_matrix/client/v3".freeze

      def initialize(homeserver_url, token)
        @base  = homeserver_url.to_s
        @token = token
      end

      # The bot's own MXID, e.g. "@opilot:localhost".
      def whoami
        request(Net::HTTP::Get, "/account/whoami").fetch("user_id")
      end

      # The display name, or nil. Element's mention pill puts it in `body`.
      def display_name(user_id)
        request(Net::HTTP::Get, "/profile/#{esc(user_id)}/displayname")["displayname"]
      rescue Error
        nil
      end

      def joined_rooms
        Array(request(Net::HTTP::Get, "/joined_rooms")["joined_rooms"])
      end

      # One non-blocking sync. `filter` is a filter object, sent inline.
      def sync(since:, filter:)
        query = { "timeout" => "0", "filter" => JSON.generate(filter) }
        query["since"] = since if since
        request(Net::HTTP::Get, "/sync?#{URI.encode_www_form(query)}")
      end

      # A bot reply (m.notice), anchored to the message it answers — inside the
      # thread when `thread_root` is given. The same txn_id twice is one message:
      # the homeserver de-duplicates it.
      def send_notice(room_id, body, txn_id:, reply_to: nil, thread_root: nil, mention: nil)
        content = { "msgtype" => "m.notice", "body" => body }
        if thread_root
          content["m.relates_to"] = { "rel_type" => "m.thread", "event_id" => thread_root, "is_falling_back" => true,
                                      "m.in_reply_to" => { "event_id" => reply_to || thread_root } }
        elsif reply_to
          content["m.relates_to"] = { "m.in_reply_to" => { "event_id" => reply_to } }
        end
        content["m.mentions"] = { "user_ids" => [mention].compact }
        path = "/rooms/#{esc(room_id)}/send/m.room.message/#{esc(txn_id)}"
        request(Net::HTTP::Put, path, content).fetch("event_id")
      end

      # Best-effort reaction, e.g. 👀 when opilot starts on a message.
      def react(room_id, event_id, key, txn_id:)
        content = { "m.relates_to" => { "rel_type" => "m.annotation", "event_id" => event_id, "key" => key } }
        request(Net::HTTP::Put, "/rooms/#{esc(room_id)}/send/m.reaction/#{esc(txn_id)}", content)
        true
      rescue Error
        false
      end

      # Best-effort "is typing" indicator.
      def typing(room_id, user_id, typing: true, timeout_ms: 120_000)
        body = typing ? { "typing" => true, "timeout" => timeout_ms } : { "typing" => false }
        request(Net::HTTP::Put, "/rooms/#{esc(room_id)}/typing/#{esc(user_id)}", body)
        true
      rescue Error
        false
      end

      private

      def esc(segment)
        URI.encode_www_form_component(segment.to_s).gsub("+", "%20")
      end

      # Parsed JSON body; raises Error on anything but 2xx (Clients::HTTP has
      # already retried a 429/5xx). Errors name the path and errcode, never the token.
      def request(verb, path, body = nil)
        code, parsed = HTTP.request_json(verb, "#{@base}#{API}#{path}", token: @token, body: body, bearer: true)
        unless (200..299).cover?(code)
          detail = parsed.is_a?(Hash) ? " #{parsed["errcode"]}: #{parsed["error"]}" : ""
          raise Error, "Matrix #{verb::METHOD} #{path.split("?").first} returned HTTP #{code}#{detail}"
        end
        parsed.is_a?(Hash) ? parsed : {}
      rescue HTTP::Error => e
        raise Error, "could not reach the Matrix homeserver at #{@base}: #{scrub(e.message)}"
      end

      def scrub(msg)
        @token ? msg.gsub(@token, "[token]") : msg
      end
    end
  end
end
