require_relative "../test_helper"

module OPilot
  class UsageRunnerTest < Minitest::Test
    CtxDouble = Struct.new(:authgw_url, :gw_token, keyword_init: true)

    def ctx(**over)
      CtxDouble.new(authgw_url: "http://authgw.test:47292", gw_token: "gw-token", **over)
    end

    def test_raises_without_a_gateway_token
      assert_raises(OPilot::FatalError) { UsageRunner.new(ctx(gw_token: nil)).run }
    end

    def test_prints_account_and_key_balance
      stub_request(:get, "http://authgw.test:47292/api/v1/credits")
        .to_return(status: 200, body: '{"data":{"total_credits":100,"total_usage":1.875817337}}')
      stub_request(:get, "http://authgw.test:47292/api/v1/key")
        .to_return(status: 200, body: '{"data":{"usage":0.278890834,"limit":100,"limit_remaining":99.721109166,"is_free_tier":false}}')
      stub_request(:get, "http://authgw.test:47292/api/v1/models")
        .to_return(status: 200, body: catalog_body)

      out, = capture_io { UsageRunner.new(ctx).run }

      assert_includes out, "OpenRouter usage"
      assert_includes out, "$1.88 used of $100.00 purchased"
      assert_includes out, "$98.12 remaining"
      assert_includes out, "$0.28 used"
      assert_includes out, "limit $100.00, $99.72 remaining"
      assert_includes out, "Work model anthropic/claude-opus-4.8"
      assert_includes out, "$5.00/1M prompt   $25.00/1M completion"
      assert_includes out, "Fast model anthropic/claude-haiku-4.5"
      assert_includes out, "$1.00/1M prompt   $5.00/1M completion"
    end

    def test_reports_no_per_key_limit_when_the_key_has_none
      stub_request(:get, "http://authgw.test:47292/api/v1/credits")
        .to_return(status: 200, body: '{"data":{"total_credits":50,"total_usage":0}}')
      stub_request(:get, "http://authgw.test:47292/api/v1/key")
        .to_return(status: 200, body: '{"data":{"usage":0,"limit":null,"is_free_tier":true}}')
      stub_request(:get, "http://authgw.test:47292/api/v1/models")
        .to_return(status: 200, body: '{"data":[]}')

      out, = capture_io { UsageRunner.new(ctx).run }

      assert_includes out, "no per-key limit"
      assert_includes out, "free tier"
      assert_includes out, "not found in the OpenRouter model catalog"
    end

    def test_wraps_client_errors_as_fatal
      stub_request(:get, "http://authgw.test:47292/api/v1/credits")
        .to_return(status: 401, body: "unauthorized")

      assert_raises(OPilot::FatalError) { capture_io { UsageRunner.new(ctx).run } }
    end

    private

    # Matches Harness::MODEL_WORK/MODEL_FAST's defaults with the "openrouter/"
    # prefix stripped, since that's how the OpenRouter catalog names them.
    def catalog_body
      JSON.generate(data: [
        { "id" => "anthropic/claude-opus-4.8", "pricing" => { "prompt" => "0.000005", "completion" => "0.000025" } },
        { "id" => "anthropic/claude-haiku-4.5", "pricing" => { "prompt" => "0.000001", "completion" => "0.000005" } }
      ])
    end
  end
end
