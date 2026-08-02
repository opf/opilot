require "net/http"
require "uri"
require "json"
require "retriable"

module Chomper
  module Clients
    module HTTP
    Error = Class.new(RuntimeError)

    # Raised inside retriable blocks for transient HTTP status codes (429, 5xx).
    TransientError = Class.new(RuntimeError)

    RETRYABLE_CODES = [429, 500, 502, 503, 504].freeze

    # Retry tuning. base_interval is overridable so the test suite can disable
    # real backoff sleeps (see test/test_helper.rb).
    @max_tries     = 3
    @base_interval = 10
    class << self
      attr_accessor :max_tries, :base_interval
    end

    def self.retry_opts
      {
        on: [
          TransientError,
          SocketError, Net::OpenTimeout, Net::ReadTimeout,
          # EOFError is the "end of file reached" raised when the peer drops the
          # connection mid-response — a transient blip, not a permanent failure.
          EOFError,
          Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE,
          Errno::EHOSTUNREACH, Errno::ENETUNREACH
        ],
        tries: max_tries,
        base_interval: base_interval,
        multiplier: 1.0,
        on_retry: proc { |e, try, _, next_interval|
          # next_interval is nil on the final attempt (retriable signalling give-up).
          wait = next_interval ? " — retrying in #{next_interval.round}s…" : ""
          warn "  ⚠ #{e.class} (attempt #{try})#{wait}"
        }
      }
    end

    # Returns [status_code, body_string]. Never raises on HTTP status codes
    # (including persistent 5xx after retries); only raises Error on network failures.
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

    # Returns [status_code, raw_bytes]. Unlike .get this does not assume text —
    # it is for attachment content, which is arbitrary binary. OpenProject's
    # attachment `downloadLocation` 302s to wherever the file actually lives
    # (local storage, S3, …), and .request never follows redirects, so this
    # follows up to MAX_REDIRECTS of them. The token is only sent on the first
    # hop: a redirect to presigned storage carries its own credentials in the
    # URL, and forwarding an OpenProject API key to a third-party host would
    # leak it.
    MAX_REDIRECTS   = 3
    REDIRECT_CODES  = [301, 302, 303, 307, 308].freeze

    def self.get_binary(url, token:, hops: MAX_REDIRECTS)
      code, body, location = request_raw(Net::HTTP::Get, url, token: token)
      return [code, body] unless REDIRECT_CODES.include?(code) && location

      raise Error, "too many redirects fetching #{url}" if hops.zero?
      # token: nil on the follow — dropping the credential falls out of the
      # recursive call rather than needing a "is this the first hop?" flag.
      get_binary(URI.join(url, location).to_s, token: nil, hops: hops - 1)
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
      code, resp_body, = request_raw(verb, url, token: token, body: body)
      [code, resp_body]
    end

    # As .request, but also returns the Location header so .get_binary can follow
    # redirects, and sends no JSON Content-Type when there is no body (an
    # attachment download is not a JSON request). A nil token skips auth
    # entirely — see .get_binary on why redirect hops must not carry the key.
    private_class_method def self.request_raw(verb, url, token:, body: nil)
      uri = URI(url)
      last_response = nil
      Retriable.retriable(**retry_opts) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        read_timeout: 30, open_timeout: 10) do |http|
          req = verb.new(uri)
          req.basic_auth("apikey", token) if token
          req["Content-Type"] = "application/json" if body
          req.body = JSON.generate(body) if body
          res = http.request(req)
          last_response = [res.code.to_i, res.body, res["location"]]
          raise TransientError, "HTTP #{res.code}" if RETRYABLE_CODES.include?(res.code.to_i)
          last_response
        end
      end
    rescue TransientError
      # Retries exhausted on a retryable status code — return the last response
      # rather than raising, so callers can degrade on persistent 5xx/429.
      last_response
    rescue => e
      raise Error, "HTTP request failed for #{url}: #{e.message}"
    end
    end
  end
end
