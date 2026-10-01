require_relative "../../../test_helper"

module OPilot
  class OpenProjectResponseTest < Minitest::Test
    OP = Clients::OpenProject
    BASE = "https://op.test".freeze

    def response(code, body) = OP::Response.new(code, body, "GET work_packages/42")

    def test_value_returns_the_body_of_a_success
      assert_equal({ "id" => 42 }, response(200, { "id" => 42 }).value!)
      assert_nil response(204, nil).value!, "204 carries no body by design"
    end

    def test_a_form_verdict_is_read_from_the_body_not_the_status
      rejected = response(200, { "_embedded" => { "validationErrors" => { "customField7" => { "message" => "can't be blank" } } } })
      assert rejected.form_answered?
      assert_equal ["customField7"], rejected.validation_errors.keys, "a form answers 200 for a payload it rejects"

      accepted = response(200, { "_embedded" => { "validationErrors" => {} } })
      assert accepted.form_answered?
      assert_nil accepted.validation_errors
    end

    def test_a_form_that_did_not_run_gives_no_verdict
      [response(403, { "message" => "no" }), response(200, "<html>proxy</html>")].each do |form|
        refute form.form_answered?
        assert_nil form.validation_errors
      end
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

    def test_a_network_error_has_no_code
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
