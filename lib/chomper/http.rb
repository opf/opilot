require "net/http"
require "uri"
require "json"
require "retriable"

module Chomper
  module HTTP
    Error = Class.new(RuntimeError)

    # Raised inside retriable blocks for transient HTTP status codes (429, 5xx).
    TransientError = Class.new(RuntimeError)

    RETRYABLE_CODES = [429, 500, 502, 503, 504].freeze

    RETRY_OPTS = {
      on: [
        TransientError,
        SocketError, Net::OpenTimeout, Net::ReadTimeout,
        Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE
      ],
      tries: 3,
      base_interval: 10,
      multiplier: 1.0,
      on_retry: proc { |e, try, _, next_interval|
        warn "  ⚠ #{e.class} (attempt #{try}) — retrying in #{next_interval.round}s…"
      }
    }.freeze

    # Returns [status_code, body_string]. Never raises on HTTP errors.
    def self.get(url, token:)
      request(Net::HTTP::Get, url, token: token)
    end

    # Returns [status_code, parsed_hash_or_nil].
    def self.get_json(url, token:)
      code, body = get(url, token: token)
      parsed = JSON.parse(body) rescue nil
      [code, parsed]
    end

    # Returns [status_code, parsed_hash], raises on non-200.
    def self.get_json!(url, token:)
      code, parsed = get_json(url, token: token)
      raise Error, "#{url} returned HTTP #{code}" unless code == 200
      [code, parsed]
    end

    def self.post_json(url, body, token:)
      code, raw = request(Net::HTTP::Post, url, token: token, body: body)
      parsed = JSON.parse(raw) rescue nil
      [code, parsed]
    end

    def self.patch_json(url, body, token:)
      code, raw = request(Net::HTTP::Patch, url, token: token, body: body)
      parsed = JSON.parse(raw) rescue nil
      [code, parsed]
    end

    def self.encode_filters(filters_json)
      URI.encode_www_form_component(filters_json)
    end

    private_class_method def self.request(verb, url, token:, body: nil)
      uri = URI(url)
      Retriable.retriable(**RETRY_OPTS) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        read_timeout: 30, open_timeout: 10) do |http|
          req = verb.new(uri)
          req.basic_auth("apikey", token)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body) if body
          res = http.request(req)
          raise TransientError, "HTTP #{res.code}" if RETRYABLE_CODES.include?(res.code.to_i)
          [res.code.to_i, res.body]
        end
      end
    rescue => e
      raise Error, "HTTP request failed for #{url}: #{e.message}"
    end
  end
end
