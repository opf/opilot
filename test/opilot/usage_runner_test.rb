require_relative "../test_helper"

module OPilot
  class UsageRunnerTest < Minitest::Test
    CtxDouble = Struct.new(:authgw_url, :gw_token, :inference_url, keyword_init: true)

    def ctx(**over)
      CtxDouble.new(authgw_url: "http://authgw.test:47292", gw_token: "gw-token",
                    inference_url: "https://openrouter.ai/api/v1", **over)
    end

    # Swap the pinned models for a self-hosted pair. The provider prefix is the
    # only signal `usage` reads to decide whether spend applies.
    def use_self_hosted_models
      Harness.send(:remove_const, :MODEL_HEAVY)
      Harness.const_set(:MODEL_HEAVY, "local/qwen2.5-coder:32b")
      Harness.send(:remove_const, :MODEL_LIGHT)
      Harness.const_set(:MODEL_LIGHT, "local/qwen2.5-coder:7b")
    end

    # Pin the two models for the duration of the test, regardless of what a
    # local .env resolves OPILOT_MODEL_HEAVY/LIGHT to — otherwise a config that
    # points both tiers at the same model (a legitimate thing to do) collides
    # with the two distinct fake catalog entries below and pricing lookup
    # can't tell them apart.
    def setup
      @orig_heavy = Harness::MODEL_HEAVY
      @orig_light = Harness::MODEL_LIGHT
      Harness.send(:remove_const, :MODEL_HEAVY)
      Harness.const_set(:MODEL_HEAVY, "openrouter/anthropic/claude-opus-4.8")
      Harness.send(:remove_const, :MODEL_LIGHT)
      Harness.const_set(:MODEL_LIGHT, "openrouter/anthropic/claude-haiku-4.5")
    end

    def teardown
      Harness.send(:remove_const, :MODEL_HEAVY)
      Harness.const_set(:MODEL_HEAVY, @orig_heavy)
      Harness.send(:remove_const, :MODEL_LIGHT)
      Harness.const_set(:MODEL_LIGHT, @orig_light)
    end

    def test_raises_without_a_gateway_token
      assert_raises(OPilot::FatalError) { UsageRunner.new(ctx(gw_token: nil)).run }
    end

    def test_prints_account_and_key_balance
      stub_request(:get, "http://authgw.test:47292/v1/credits")
        .to_return(status: 200, body: '{"data":{"total_credits":100,"total_usage":1.875817337}}')
      stub_request(:get, "http://authgw.test:47292/v1/key")
        .to_return(status: 200, body: '{"data":{"usage":0.278890834,"limit":100,"limit_remaining":99.721109166,"is_free_tier":false}}')
      stub_request(:get, "http://authgw.test:47292/v1/models")
        .to_return(status: 200, body: catalog_body)

      out, = capture_io { UsageRunner.new(ctx).run }

      assert_includes out, "OpenRouter usage"
      assert_includes out, "$1.88 used of $100.00 purchased"
      assert_includes out, "$98.12 remaining"
      assert_includes out, "$0.28 used"
      assert_includes out, "limit $100.00, $99.72 remaining"
      assert_includes out, "Heavy model anthropic/claude-opus-4.8"
      assert_includes out, "$5.00/1M prompt   $25.00/1M completion"
      assert_includes out, "Light model anthropic/claude-haiku-4.5"
      assert_includes out, "$1.00/1M prompt   $5.00/1M completion"
    end

    def test_reports_no_per_key_limit_when_the_key_has_none
      stub_request(:get, "http://authgw.test:47292/v1/credits")
        .to_return(status: 200, body: '{"data":{"total_credits":50,"total_usage":0}}')
      stub_request(:get, "http://authgw.test:47292/v1/key")
        .to_return(status: 200, body: '{"data":{"usage":0,"limit":null,"is_free_tier":true}}')
      stub_request(:get, "http://authgw.test:47292/v1/models")
        .to_return(status: 200, body: '{"data":[]}')

      out, = capture_io { UsageRunner.new(ctx).run }

      assert_includes out, "no per-key limit"
      assert_includes out, "free tier"
      assert_includes out, "not found in the OpenRouter model catalog"
    end

    def test_wraps_client_errors_as_fatal
      stub_request(:get, "http://authgw.test:47292/v1/credits")
        .to_return(status: 401, body: "unauthorized")

      assert_raises(OPilot::FatalError) { capture_io { UsageRunner.new(ctx).run } }
    end

    # A self-hosted upstream has no /credits or /key — those are OpenRouter's
    # own endpoints. WebMock stubs nothing here on purpose: net connections are
    # disabled globally, so any HTTP call at all fails this test. That is the
    # assertion that matters, more than the printed strings.
    def test_reports_configuration_instead_of_spend_for_a_self_hosted_upstream
      use_self_hosted_models

      out, = capture_io { UsageRunner.new(ctx(inference_url: "http://10.0.0.5:8000/v1")).run }

      assert_includes out, "http://10.0.0.5:8000/v1"
      assert_includes out, "local/qwen2.5-coder:32b"
      assert_includes out, "local/qwen2.5-coder:7b"
      assert_includes out, "no spend to report"
      refute_includes out, "not found in the OpenRouter model catalog"
    end

    def test_still_requires_a_gateway_token_on_a_self_hosted_upstream
      use_self_hosted_models

      assert_raises(OPilot::FatalError) { UsageRunner.new(ctx(gw_token: nil)).run }
    end

    private

    # Matches the pinned MODEL_HEAVY/MODEL_LIGHT (see setup) with the
    # "openrouter/" prefix stripped, since that's how the OpenRouter catalog
    # names them.
    def catalog_body
      JSON.generate(data: [
        { "id" => "anthropic/claude-opus-4.8", "pricing" => { "prompt" => "0.000005", "completion" => "0.000025" } },
        { "id" => "anthropic/claude-haiku-4.5", "pricing" => { "prompt" => "0.000001", "completion" => "0.000005" } }
      ])
    end
  end
end
