require "rainbow"

module OPilot
  # `./opilot usage` — reports inference spend without ever handling the real
  # API key: it asks inference-gw, the sidecar that holds it, the same way pi asks
  # for inference. No OpenProject/GitHub config needed, so unlike the other
  # terminal modes this never calls Context#load_config!.
  #
  # Spend only exists on OpenRouter — `/credits` and `/key` are its own
  # endpoints, not part of any OpenAI-compatible API — so a self-hosted upstream
  # gets a configuration summary instead. The signal is the model slug's provider
  # prefix (see Harness::MODEL_HEAVY).
  class UsageRunner
    def initialize(ctx)
      @ctx = ctx
    end

    def run
      raise OPilot::FatalError, <<~MSG.strip unless @ctx.gw_token
        inference-gw isn't reachable — this must run through `./opilot usage`
        (`bin/opilot usage` alone has no OPILOT_GW_TOKEN to authenticate with).
      MSG

      return print_self_hosted_report unless openrouter?

      client  = Clients::OpenRouter.new(@ctx.inference_gw_url, @ctx.gw_token)
      credits = client.credits
      key     = client.key
      catalog = client.models
      print_report(credits, key, catalog)
    rescue Clients::OpenRouter::Error => e
      raise OPilot::FatalError, e.message
    end

    private

    def openrouter?
      Harness::MODEL_HEAVY.split("/").first == "openrouter"
    end

    # No account, no balance, no catalog — a self-hosted endpoint bills nothing
    # and publishes no pricing. Report what opilot is configured to call, so
    # `usage` still answers "what is this run actually using" rather than
    # failing or printing "not found" three times.
    def print_self_hosted_report
      puts ""
      puts Rainbow("Inference configuration").bold
      puts ""
      puts "  Upstream    #{@ctx.inference_url}"
      puts "  Heavy model #{Harness::MODEL_HEAVY}"
      puts "  Light model #{Harness::MODEL_LIGHT}"
      puts ""
      puts "  This is a self-hosted upstream, so there is no spend to report."
      puts ""
    end

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

    # Pricing for the two models opilot is actually configured to call
    # (OPILOT_MODEL_HEAVY / OPILOT_MODEL_LIGHT via Harness::MODEL_HEAVY/MODEL_LIGHT),
    # not the whole catalog — a slug that isn't in it (a typo'd override) shows
    # up here as "not found" instead of surfacing three plan calls later as a
    # confusing 400 from OpenRouter.
    def print_model_pricing(catalog)
      { "Heavy model" => Harness::MODEL_HEAVY, "Light model" => Harness::MODEL_LIGHT }.each do |label, slug|
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
