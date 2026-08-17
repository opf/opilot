require_relative "../../test_helper"

module OPilot
  module Clients
    class OpenRouterTest < Minitest::Test
      URL = "http://authgw.test:47292".freeze

      def setup
        @client = OpenRouter.new(URL, "gw-token")
      end

      def test_credits_sends_the_gateway_token_and_returns_the_data_hash
        stub_request(:get, "#{URL}/api/v1/credits")
          .with(headers: { "Authorization" => "Bearer gw-token" })
          .to_return(status: 200, body: '{"data":{"total_credits":100,"total_usage":1.5}}')

        data = @client.credits
        assert_equal 100, data["total_credits"]
        assert_equal 1.5, data["total_usage"]
      end

      def test_key_returns_the_data_hash
        stub_request(:get, "#{URL}/api/v1/key")
          .to_return(status: 200, body: '{"data":{"label":"sk-or-…","usage":0.28,"limit":100,"limit_remaining":99.7,"is_free_tier":false}}')

        data = @client.key
        assert_equal 0.28, data["usage"]
        assert_equal 100, data["limit"]
      end

      def test_models_returns_the_catalog_array
        stub_request(:get, "#{URL}/api/v1/models")
          .to_return(status: 200, body: '{"data":[{"id":"anthropic/claude-opus-4.8","pricing":{"prompt":"0.000005","completion":"0.000025"}}]}')

        catalog = @client.models
        assert_equal 1, catalog.length
        assert_equal "anthropic/claude-opus-4.8", catalog.first["id"]
      end

      def test_non_200_raises
        stub_request(:get, "#{URL}/api/v1/key").to_return(status: 401, body: "unauthorized")
        assert_raises(OpenRouter::Error) { @client.key }
      end

      def test_malformed_json_raises
        stub_request(:get, "#{URL}/api/v1/key").to_return(status: 200, body: "not json")
        assert_raises(OpenRouter::Error) { @client.key }
      end

      def test_network_failure_raises_wrapped_error
        stub_request(:get, "#{URL}/api/v1/key").to_raise(SocketError.new("no route"))
        err = assert_raises(OpenRouter::Error) { @client.key }
        assert_includes err.message, "authgw"
      end
    end
  end
end
