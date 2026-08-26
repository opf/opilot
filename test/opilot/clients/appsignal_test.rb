require_relative "../../test_helper"

module OPilot
  module Clients
    # The four-call assembly, and the two things that would fail silently: the
    # token leaking into a log, and a missing trace losing the whole incident.
    class AppSignalTest < Minitest::Test
      GQL = "https://appsignal.com/graphql".freeze
      V2  = "https://appsignal.com/api/v2".freeze
      APP = "app123".freeze

      def setup
        @client = AppSignal.new("secret-token")
      end

      # Both APIs answer with a JSON body; the two names say which one a stub is
      # standing in for, and read better at the call sites than one would.
      def gql(body)  = { status: 200, body: JSON.generate(body) }
      alias rows gql

      def incident_body(digests: ["dig1"])
        gql("data" => { "app" => { "incident" => {
          "number" => 2025, "exceptionName" => "MCP::Server::RequestHandlerError",
          "exceptionMessage" => "Invalid params", "digests" => digests, "count" => 1
        } } })
      end

      def backtrace_body
        gql("data" => { "app" => { "backtrace" => [
          { "path" => "lib/mcp/server.rb", "line" => "661", "method" => "validate_initialize_params!" }
        ] } })
      end

      def span
        { "action_name" => "POST::API::Mcp#/", "revision" => "17.9.0",
          "status_message" => "Invalid params",
          "span_attributes" => {
            "appsignal.request.payload" => '{"id":1,"method":"initialize"}',
            "appsignal.request.session_data" => "{}",
            "appsignal.tag.request_id" => "abc", "appsignal.tag.hostname" => "web-1",
            "http.request.header.accept" => "application/json",
            "appsignal.self_allocation_count" => "12"
          },
          "events.attributes" => [{ "appsignal.stacktrace_id" => "st-1",
                                    "exception.type" => "MCP::Server::RequestHandlerError" }, {}] }
      end

      # GraphQL is one URL for two different queries, so they are answered in
      # call order: incident first, backtrace last (the backtrace needs the
      # stacktrace_id only the trace reports).
      def stub_happy_path
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}}).to_return(incident_body, backtrace_body)
        stub_request(:post, "#{V2}/tracing/traces/errors").to_return(rows([{ "trace_id" => "t1" }]))
        stub_request(:post, "#{V2}/tracing/trace/error").to_return(rows([span]))
      end

      def test_it_assembles_metadata_payload_and_backtrace
        stub_happy_path
        inc = @client.incident(APP, 2025)

        assert_equal "Invalid params", inc["exceptionMessage"]
        assert_equal({ "id" => 1, "method" => "initialize" }, inc.dig("request", "payload"),
                     "the payload is parsed, not left as an escaped string")
        assert_equal 1, inc["backtrace"].length
        assert_equal "lib/mcp/server.rb", inc["backtrace"].first["path"]
      end

      # Only request-describing attributes are lifted; an incident file must not
      # carry every span attribute the agent happened to record.
      def test_it_lifts_only_the_request_attributes
        stub_happy_path
        req = @client.incident(APP, 2025)["request"]

        assert_equal "POST::API::Mcp#/", req["action"]
        assert_equal({ "request_id" => "abc", "hostname" => "web-1" }, req["tags"])
        assert_equal({ "accept" => "application/json" }, req["headers"])
        refute_includes req.keys, "appsignal.self_allocation_count"
      end

      # V2 takes a Bearer header, so its token never reaches a URL. GraphQL has
      # no header form at all — hence the scrubbing test below.
      def test_v2_authenticates_by_header
        stub_happy_path
        @client.incident(APP, 2025)
        assert_requested(:post, "#{V2}/tracing/trace/error",
                         headers: { "Authorization" => "Bearer secret-token" })
      end

      # The GraphQL token lives in the query string, and Clients::HTTP-style
      # error strings are built from URLs. Nothing raised may carry it.
      def test_a_raised_error_never_contains_the_token
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}}).to_return(status: 500, body: "boom")
        err = assert_raises(AppSignal::Error) { @client.incident(APP, 2025) }

        refute_includes err.message, "secret-token"
        assert_includes err.message, "token=[redacted]"
      end

      def test_a_network_failure_is_scrubbed_too
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}}).to_raise(SocketError.new("no route"))
        err = assert_raises(AppSignal::Error) { @client.incident(APP, 2025) }
        refute_includes err.message, "secret-token"
      end

      # A GraphQL error arrives inside a 200.
      def test_a_graphql_error_in_a_200_is_a_failure
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}})
          .to_return(gql("errors" => [{ "message" => "No such app" }]))
        err = assert_raises(AppSignal::Error) { @client.incident(APP, 2025) }
        assert_includes err.message, "No such app"
      end

      def test_an_unknown_incident_is_a_named_failure
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}})
          .to_return(gql("data" => { "app" => { "incident" => {} } }))
        err = assert_raises(AppSignal::Error) { @client.incident(APP, 9999) }
        assert_includes err.message, "no exception incident #9999"
      end

      # A trace that has aged out costs the payload AND the backtrace — the
      # backtrace hangs off the trace's stacktrace_id — but the incident itself
      # is still worth reporting.
      def test_an_incident_with_no_trace_still_returns
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}}).to_return(incident_body)
        stub_request(:post, "#{V2}/tracing/traces/errors").to_return(rows([]))
        inc = @client.incident(APP, 2025)

        assert_equal "Invalid params", inc["exceptionMessage"]
        refute_includes inc.keys, "request"
        refute_includes inc.keys, "backtrace"
      end

      def test_an_incident_with_no_digest_skips_the_trace_lookup
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}}).to_return(incident_body(digests: []))
        @client.incident(APP, 2025)
        assert_not_requested :post, "#{V2}/tracing/traces/errors"
      end

      # The backtrace is the last call and the least essential — a failure there
      # must not throw away the payload already in hand.
      def test_a_failing_backtrace_query_keeps_the_payload
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}})
          .to_return(incident_body, { status: 500, body: "boom" })
        stub_request(:post, "#{V2}/tracing/traces/errors").to_return(rows([{ "trace_id" => "t1" }]))
        stub_request(:post, "#{V2}/tracing/trace/error").to_return(rows([span]))

        inc = @client.incident(APP, 2025)
        assert_equal({ "id" => 1, "method" => "initialize" }, inc.dig("request", "payload"))
        refute_includes inc.keys, "backtrace"
      end

      # `cursor` is required even for a first page — the API 400s without it.
      def test_the_trace_query_sends_the_pagination_the_api_demands
        stub_happy_path
        @client.incident(APP, 2025)
        assert_requested(:post, "#{V2}/tracing/traces/errors") do |req|
          page = JSON.parse(req.body)["pagination"]
          page["order"] == "DESC" && page["cursor"].key?("time") && page["per_page"] == 1
        end
      end

      def test_applications_flattens_organizations
        stub_request(:post, %r{\A#{Regexp.escape(GQL)}}).to_return(gql("data" => { "viewer" => {
          "organizations" => [{ "apps" => [{ "id" => "a1", "name" => "one", "environment" => "production" }] },
                              { "apps" => [{ "id" => "a2", "name" => "two", "environment" => "staging" }] }]
        } }))
        assert_equal %w[a1 a2], @client.applications.map { |a| a["id"] }
      end
    end
  end
end
