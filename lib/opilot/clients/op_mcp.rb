require "net/http"
require "uri"
require "json"

module OPilot
  module Clients
    # Reads mcp-gw's runner-only `GET /tools` route (see MCP.md, Step 1) — the
    # UNFILTERED tools/list the instance actually offers. Used once at startup
    # by Helpers#report_mcp_status, purely to report what an administrator
    # has enabled; it is never on the path of a real op_query call, which is
    # entirely the harness/extension's job through `POST /mcp`.
    class OpMcp
      Error = Class.new(StandardError)
      # The instance has no Enterprise MCP server enabled — a NORMAL state
      # (MCP.md: "Availability is per instance"), not a failure. Since
      # Context#op_mcp? defaults ON, this is the common case for any instance
      # without the add-on, so it is reported distinctly rather than through
      # the generic warning #summary's caller prints for a real Error.
      Unavailable = Class.new(Error)

      # Mirrors mcp-gw.js's READ_ONLY_OPS. This copy is diagnostic only — it
      # never decides what a call can do, only how the startup summary counts
      # and labels what the instance returned. The two run in different
      # processes, so the duplication is unavoidable; mcp-gw.js is the authority.
      READ_ONLY_OPS = %w[
        search_work_packages list_work_package_comments list_work_package_relations
        search_projects search_versions list_types list_statuses search_custom_fields
      ].freeze

      def initialize(mcp_gw_url, gw_token)
        @uri      = URI(mcp_gw_url)
        @gw_token = gw_token
      end

      # The instance's full, unfiltered tool-name list. Raises Unavailable on a
      # 404 (no MCP server on this instance) and Error on anything else but a
      # clean 200 JSON-RPC answer — the caller decides how to report each
      # (Helpers#report_mcp_status treats both as a warning, never a failure).
      def tool_names
        target = @uri.dup
        target.path = "/tools"
        res = Net::HTTP.start(target.host, target.port, read_timeout: 5, open_timeout: 5) do |http|
          req = Net::HTTP::Get.new(target)
          req["Authorization"] = "Bearer #{@gw_token}"
          http.request(req)
        end
        raise Unavailable, "no MCP server on this instance" if res.is_a?(Net::HTTPNotFound)
        raise Error, "mcp-gw returned HTTP #{res.code} for /tools: #{res.body}" unless res.is_a?(Net::HTTPSuccess)

        parsed = JSON.parse(res.body) rescue nil
        tools  = parsed&.dig("result", "tools")
        raise Error, "mcp-gw returned a malformed tools/list answer" unless tools.is_a?(Array)
        tools.filter_map { |t| t["name"] }
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach mcp-gw at #{target}: #{e.message}"
      end

      # One short line for the startup log. Counts rather than names, since it
      # prints every run; the signal is that write tools are enabled, which only
      # an administrator can change.
      def summary
        names   = tool_names
        allowed = names & READ_ONLY_OPS
        writes  = (names - READ_ONLY_OPS).grep(/\A(create|update|delete)_/)
        line = "#{allowed.length}/#{names.length} tools allowed by mcp-gw"
        writes.empty? ? line : "#{line}, #{writes.length} write tool(s) enabled on the instance"
      end
    end
  end
end
