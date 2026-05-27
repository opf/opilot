require_relative "../test_helper"

module Chomper
  class HTTPTest < Minitest::Test
    URL = "https://example.openproject.com/api/v3/test"

    def test_encode_filters_uri_encodes
      encoded = HTTP.encode_filters('[{"status":{"operator":"=","values":["1"]}}]')
      refute_includes encoded, "["
      refute_includes encoded, "{"
      refute_includes encoded, " "
    end

    def test_get_returns_status_and_body
      stub_request(:get, URL).to_return(status: 200, body: "hello")
      code, body = HTTP.get(URL, token: "tok")
      assert_equal 200, code
      assert_equal "hello", body
    end

    def test_get_basic_auth_uses_apikey
      stub_request(:get, URL)
        .with(basic_auth: ["apikey", "mytoken"])
        .to_return(status: 200, body: "ok")
      code, = HTTP.get(URL, token: "mytoken")
      assert_equal 200, code
    end

    def test_get_json_parses_body
      stub_request(:get, URL).to_return(status: 200, body: '{"total":5}')
      code, parsed = HTTP.get_json(URL, token: "tok")
      assert_equal 200, code
      assert_equal 5, parsed["total"]
    end

    def test_get_json_returns_nil_on_malformed_body
      stub_request(:get, URL).to_return(status: 200, body: "not json at all")
      code, parsed = HTTP.get_json(URL, token: "tok")
      assert_equal 200, code
      assert_nil parsed
    end

    def test_get_json_non_200_returns_code_and_nil
      stub_request(:get, URL).to_return(status: 404, body: '{"error":"not found"}')
      code, _parsed = HTTP.get_json(URL, token: "tok")
      assert_equal 404, code
    end

    def test_get_json_bang_raises_on_non_200
      stub_request(:get, URL).to_return(status: 404, body: "{}")
      assert_raises(HTTP::Error) { HTTP.get_json!(URL, token: "tok") }
    end

    def test_get_json_bang_returns_on_200
      stub_request(:get, URL).to_return(status: 200, body: '{"key":"val"}')
      code, parsed = HTTP.get_json!(URL, token: "tok")
      assert_equal 200, code
      assert_equal "val", parsed["key"]
    end

    def test_get_raises_http_error_on_network_failure
      stub_request(:get, URL).to_raise(SocketError.new("connection refused"))
      assert_raises(HTTP::Error) { HTTP.get(URL, token: "tok") }
    end
  end
end
