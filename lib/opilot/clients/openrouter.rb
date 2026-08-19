require "net/http"
require "uri"
require "json"

module OPilot
  module Clients
    # Reads OpenRouter's own account/key endpoints through authgw, which holds
    # the real API key. The runner never sees it: it authenticates with the
    # non-secret gateway token (OPILOT_GW_TOKEN), exactly as pi does, and authgw
    # swaps in the real key before forwarding.
    #
    # Paths are /v1/…, not OpenRouter's own /api/v1/…: authgw owns the upstream's
    # path prefix and re-applies it, so every client speaks one uniform /v1. Only
    # reachable when the upstream IS OpenRouter, which UsageRunner decides before
    # constructing this.
    class OpenRouter
      Error = Class.new(StandardError)

      def initialize(authgw_url, gw_token)
        @uri      = URI(authgw_url)
        @gw_token = gw_token
      end

      # { total_credits:, total_usage: } — the account's whole purchased
      # balance and lifetime spend, from GET /v1/credits.
      def credits
        get("/v1/credits")
      end

      # { label:, usage:, limit:, limit_remaining:, is_free_tier:, rate_limit: }
      # for the key authgw is configured with, from GET /v1/key. `limit` is
      # null when the key itself has no spend cap set (the account-wide balance
      # still applies) — that's OpenRouter's answer, not a lookup failure here.
      def key
        get("/v1/key")
      end

      # The full model catalog (pricing, context length, …) from GET
      # /v1/models. Public upstream (no key needed for this one), but still
      # routed through authgw so the runner never opens its own connection to
      # openrouter.ai. Returns the raw array — callers look up the one or two
      # ids they care about rather than this fetching per-id.
      def models
        get("/v1/models")
      end

      private

      def get(path)
        target = @uri.dup
        target.path = path
        res = Net::HTTP.start(target.host, target.port, read_timeout: 15, open_timeout: 5) do |http|
          req = Net::HTTP::Get.new(target)
          req["Authorization"] = "Bearer #{@gw_token}"
          http.request(req)
        end
        raise Error, "authgw returned HTTP #{res.code} for #{path}: #{res.body}" \
          unless res.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(res.body) rescue nil
        raise Error, "authgw returned a non-JSON body for #{path}" unless parsed
        parsed["data"] || parsed
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach authgw at #{target}: #{e.message}"
      end
    end
  end
end
