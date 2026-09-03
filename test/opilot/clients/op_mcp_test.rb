require_relative "../../test_helper"

module OPilot
  module Clients
    class OpMcpTest < Minitest::Test
      URL = "http://mcp-gw.test:47293".freeze

      def setup
        @client = OpMcp.new(URL, "gw-token")
      end

      def test_tool_names_sends_the_gateway_token_and_reads_the_unfiltered_list
        stub_request(:get, "#{URL}/tools")
          .with(headers: { "Authorization" => "Bearer gw-token" })
          .to_return(status: 200, body: JSON.generate(
            result: { tools: [{ name: "search_work_packages" }, { name: "create_work_package" }] }
          ))

        assert_equal %w[search_work_packages create_work_package], @client.tool_names
      end

      def test_summary_counts_allowed_and_flags_write_tools
        stub_request(:get, "#{URL}/tools")
          .to_return(status: 200, body: JSON.generate(
            result: { tools: [{ name: "search_work_packages" }, { name: "list_types" },
                               { name: "create_work_package" }, { name: "update_work_package" }] }
          ))

        summary = @client.summary
        assert_includes summary, "2/4 tools allowed by mcp-gw"
        assert_includes summary, "2 write tool(s) enabled"
        refute_includes summary, "create_work_package", "names would put ~150 chars on every startup"
      end

      # search_users is not allowlisted but cannot write, so it is not news.
      def test_summary_stays_quiet_about_reads_it_merely_does_not_allow
        stub_request(:get, "#{URL}/tools")
          .to_return(status: 200, body: JSON.generate(
            result: { tools: [{ name: "search_work_packages" }, { name: "search_users" }] }
          ))

        summary = @client.summary
        assert_includes summary, "1/2 tools allowed by mcp-gw"
        refute_includes summary, "write tool"
      end

      def test_a_404_is_unavailable_not_a_generic_error
        # The normal state for any instance without the Enterprise MCP add-on
        # enabled — Context#op_mcp? defaults ON, so this is the common case.
        stub_request(:get, "#{URL}/tools").to_return(status: 404, body: "MCP server is not available.")
        assert_raises(OpMcp::Unavailable) { @client.tool_names }
      end

      def test_other_non_200_raises_the_generic_error
        stub_request(:get, "#{URL}/tools").to_return(status: 401, body: "unauthorized")
        err = assert_raises(OpMcp::Error) { @client.tool_names }
        refute_kind_of OpMcp::Unavailable, err
      end

      def test_malformed_json_raises
        stub_request(:get, "#{URL}/tools").to_return(status: 200, body: "not json")
        assert_raises(OpMcp::Error) { @client.tool_names }
      end

      def test_network_failure_raises_wrapped_error
        stub_request(:get, "#{URL}/tools").to_raise(SocketError.new("no route"))
        err = assert_raises(OpMcp::Error) { @client.tool_names }
        assert_includes err.message, "mcp-gw"
      end
    end
  end
end
