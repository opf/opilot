require "rainbow"

module Chomper
  # `./chomper usage` — reports OpenRouter spend without ever handling the real
  # API key: it asks authgw, the sidecar that holds it, the same way pi asks
  # for inference. No OpenProject/GitHub config needed, so unlike the other
  # terminal modes this never calls Context#load_config!.
  class UsageRunner
    def initialize(ctx)
      @ctx = ctx
    end

    def run
      raise Chomper::FatalError, <<~MSG.strip unless @ctx.gw_token
        authgw isn't reachable — this must run through `./chomper usage`
        (`bin/chomper usage` alone has no CHOMPER_GW_TOKEN to authenticate with).
      MSG

      client  = Clients::OpenRouter.new(@ctx.authgw_url, @ctx.gw_token)
      credits = client.credits
      key     = client.key
      catalog = client.models
      print_report(credits, key, catalog)
    rescue Clients::OpenRouter::Error => e
      raise Chomper::FatalError, e.message
    end

    private

    def print_report(credits, key, catalog)
      puts ""
      puts Rainbow("OpenRouter usage").bold
      puts ""
      if credits["total_credits"]
        used      = credits["total_usage"].to_f
        purchased = credits["total_credits"].to_f
        puts "  Account   #{money(used)} used of #{money(purchased)} purchased  (#{money(purchased - used)} remaining)"
      end
      tier = key["is_free_tier"] ? ", free tier" : ""
      detail = key["limit"] ? "limit #{money(key["limit"])}, #{money(key["limit_remaining"].to_f)} remaining" : "no per-key limit"
      puts "  This key  #{money(key["usage"].to_f)} used  (#{detail}#{tier})"
      puts ""
      print_model_pricing(catalog)
    end

    # Pricing for the two models chomper is actually configured to call
    # (CHOMPER_MODEL / CHOMPER_TRIAGE_MODEL via Harness::MODEL_WORK/MODEL_FAST),
    # not the whole catalog — a slug that isn't in it (a typo'd override) shows
    # up here as "not found" instead of surfacing three plan calls later as a
    # confusing 400 from OpenRouter.
    def print_model_pricing(catalog)
      { "Work model" => Harness::MODEL_WORK, "Fast model" => Harness::MODEL_FAST }.each do |label, slug|
        id    = slug.delete_prefix("openrouter/")
        model = catalog.find { |m| m["id"] == id }
        line  = if model
          pricing = model["pricing"]
          "#{money_per_million(pricing["prompt"])}/1M prompt   #{money_per_million(pricing["completion"])}/1M completion"
        else
          "not found in the OpenRouter model catalog"
        end
        puts "  #{label.ljust(10)} #{id.ljust(28)} #{line}"
      end
      puts ""
    end

    def money(amount)
      format("$%.2f", amount)
    end

    def money_per_million(price_per_token)
      money(price_per_token.to_f * 1_000_000)
    end
  end
end
