require "net/http"
require "uri"
require "json"

module OPilot
  module Clients
    # Asks inference-gw what it will actually connect to. inference-gw resolves
    # OPILOT_INFERENCE_URL once at boot and re-uses that address for every
    # request, so it is the only process that can answer this — a lookup made
    # here could resolve differently, and `appsignal` gates on the answer.
    #
    # Authenticated with the non-secret gateway token, exactly as
    # Clients::OpenRouter is. Kept separate from that class, which documents
    # itself as reachable only when the upstream IS OpenRouter; this route
    # answers whatever the upstream is.
    class InferenceGw
      Error = Class.new(StandardError)

      def initialize(inference_gw_url, gw_token)
        @uri      = URI(inference_gw_url)
        @gw_token = gw_token
      end

      # { "host", "address", "port", "https" } — the configured host and the
      # address pinned for it.
      def upstream
        target = @uri.dup
        target.path = "/upstream"
        res = Net::HTTP.start(target.host, target.port, read_timeout: 5, open_timeout: 5) do |http|
          req = Net::HTTP::Get.new(target)
          req["Authorization"] = "Bearer #{@gw_token}"
          http.request(req)
        end
        raise Error, "inference-gw returned HTTP #{res.code} for /upstream" unless res.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(res.body) rescue nil
        raise Error, "inference-gw returned a non-JSON answer for /upstream" unless parsed.is_a?(Hash)
        parsed
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach inference-gw at #{target}: #{e.message}"
      end
    end
  end
end
