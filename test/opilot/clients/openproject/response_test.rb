require_relative "../../../test_helper"

module OPilot
  class OpenProjectResponseTest < Minitest::Test
    OP = Clients::OpenProject
    BASE = "https://op.test".freeze

    def response(code, body) = OP::Response.new(code, body, "GET work_packages/42")

    def test_it_destructures_and_compares_like_the_old_tuple
      code, body = response(200, { "id" => 42 })
      assert_equal [200, { "id" => 42 }], [code, body]
      assert_equal [404, nil], response(404, nil), "an Array compares equal to it"
      assert_equal response(404, nil), [404, nil]
    end

    def test_value_returns_the_body_of_a_success
      assert_equal({ "id" => 42 }, response(200, { "id" => 42 }).value!)
      assert_nil response(204, nil).value!, "204 carries no body by design"
    end

    def test_value_raises_the_class_for_each_status
      { 401 => OP::Unauthorized, 403 => OP::Forbidden, 404 => OP::NotFound, 409 => OP::Conflict,
        422 => OP::ValidationFailed, 429 => OP::RateLimited, 400 => OP::ClientError,
        503 => OP::ServerError, 200 => OP::InvalidResponse }.each do |code, klass|
        error = assert_raises(klass) { response(code, code == 200 ? nil : { "message" => "x" }).value! }
        assert_equal code, error.code
        refute_includes error.message, "message", "the body stays out of the message"
      end
    end

    def test_only_a_bad_minute_is_transient
      assert OP::Error.for(429, nil, "x").transient?
      assert OP::Error.for(502, nil, "x").transient?
      assert OP::NetworkError.new("x").transient?
      refute OP::Error.for(404, nil, "x").transient?
      assert_nil OP::NetworkError.new("x").code
    end

    def test_a_request_with_no_answer_is_a_network_error
      stub_request(:get, "#{BASE}/api/v3/users/me").to_raise(SocketError.new("no route"))
      error = assert_raises(OP::NetworkError) { OP::Client.new(BASE, "tok").me }
      assert_includes error.message, "HTTP request failed"
    end

    def test_every_endpoint_returns_a_response_naming_its_request
      stub_request(:get, "#{BASE}/api/v3/work_packages/42").to_return(status: 404, body: "{}")
      stub_request(:get, %r{/attachments/9/content}).to_return(status: 200, body: "bytes")
      client = OP::Client.new(BASE, "tok")

      update = client.update_work_package(42, {})
      assert_instance_of OP::Response, update, "the lock-version path too"
      assert_equal "GET work_packages/42", update.request
      assert_instance_of OP::Response, client.download_attachment("/api/v3/attachments/9/content")
    end
  end
end
