require "net/http"
require "uri"
require "json"

module OPilot
  module Clients
    # Reads one AppSignal exception incident — metadata, the request payload that
    # triggered it, and the full backtrace — as structured JSON.
    #
    # It takes FOUR calls across two of AppSignal's APIs, because no single one
    # of them carries a whole bug report. This was established by probing a live
    # account, not from the documentation, which is wrong or silent on most of
    # it:
    #
    #   1. GraphQL  incident(incidentNumber:)   → the digest, and the metadata
    #   2. V2       tracing/traces/errors       → a trace_id for that digest
    #   3. V2       tracing/trace/error         → THE REQUEST PAYLOAD, plus
    #                                             headers, tags, and a
    #                                             stacktrace_id
    #   4. GraphQL  backtrace(id:, revision:)   → the full frame list
    #
    # Two of those are load-bearing and non-obvious:
    #
    # THE PAYLOAD IS ONLY IN V2 TRACING. GraphQL's documented
    # `sample { params }` returns null for every incident tried, even with
    # `hasSamplesInRetention: true` and every documented argument. AppSignal's
    # MCP server does not expose params at all. The payload is what turns
    # "Invalid params" into a diagnosis, so this is why the class is shaped this
    # way rather than being one query.
    #
    # THE BACKTRACE IS BEHIND A SEPARATE QUERY. `ExceptionIncident` itself
    # carries only `firstBacktraceLine`; the frames live under
    # `app.backtrace(id:, revision:)`, keyed by the `stacktrace_id` that only the
    # V2 span reports. So step 4 depends on step 3 — the order is not incidental.
    #
    # ONE credential does all of it (a personal API token), which is the reason
    # this replaced a scoped-MCP-token client: the moment the payload is needed,
    # a personal token is required anyway, and holding a narrow token beside a
    # broad one buys nothing.
    class AppSignal
      Error = Class.new(StandardError)

      GRAPHQL_URL = "https://appsignal.com/graphql".freeze
      V2_URL      = "https://appsignal.com/api/v2".freeze

      # How far back to look for a trace carrying the payload. A trace is only
      # needed for its request data, so the most recent one for this digest is
      # the right one; the window just has to reach it.
      TRACE_WINDOW_DAYS = 30

      def initialize(token)
        @token = token
      end

      # Every app this token can see, as [{ "id", "name", "environment" }].
      def applications
        data = graphql(<<~GQL, {})
          { viewer { organizations { apps { id name environment } } } }
        GQL
        (data.dig("viewer", "organizations") || []).flat_map { |org| org["apps"] || [] }
      end

      # One incident, assembled. Returns a Hash written straight to incident.json
      # — the model reads that file, so the shape here IS the prompt's input.
      #
      # The request data is best-effort: an incident whose traces have aged out
      # still produces a usable report, just without the payload. The backtrace
      # is best-effort for the same reason, since it hangs off the trace.
      def incident(app_id, number)
        incident = fetch_incident(app_id, number)
        raise Error, "AppSignal has no exception incident ##{number} on app #{app_id}" unless incident

        trace = fetch_trace(app_id, incident["digests"])
        incident.merge(
          "request"   => trace ? request_details(trace) : nil,
          "backtrace" => trace ? fetch_backtrace(app_id, trace) : nil
        ).compact
      end

      private

      # Step 1. `... on ExceptionIncident` because `incident` is a union — a
      # number that names an anomaly incident returns a node with none of these
      # fields rather than an error.
      def fetch_incident(app_id, number)
        data = graphql(<<~GQL, "appId" => app_id, "number" => Integer(number))
          query I($appId: String!, $number: Int!) {
            app(id: $appId) {
              incident(incidentNumber: $number) {
                ... on ExceptionIncident {
                  number state severity namespace count
                  exceptionName exceptionMessage firstBacktraceLine
                  actionNames digests
                  createdAt lastOccurredAt lastSampleOccurredAt
                }
              }
            }
          }
        GQL
        found = data.dig("app", "incident")
        found && found["number"] ? found : nil
      end

      # Step 2. The digest is what links an incident to its traces. `cursor` is
      # required even for a first page, and takes the far end of the window —
      # ordering DESC then means "the most recent trace before now".
      def fetch_trace(app_id, digests)
        return nil if Array(digests).empty?

        now  = Time.now.utc
        from = (now - (TRACE_WINDOW_DAYS * 24 * 60 * 60)).strftime("%Y-%m-%dT%H:%M:%SZ")
        to   = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        rows = v2("/tracing/traces/errors",
                  "site_ids" => [app_id], "digests" => Array(digests),
                  "from" => from, "to" => to,
                  "pagination" => { "per_page" => 1, "order" => "DESC", "cursor" => { "time" => to } })
        row = rows.first
        return nil unless row && row["trace_id"]

        spans = v2("/tracing/trace/error",
                   "site_ids" => [app_id], "trace_id" => row["trace_id"], "digests" => Array(digests))
        spans.first
      end

      # Step 3's payload. The attribute names are AppSignal's own; only the ones
      # that describe the REQUEST are lifted, so an incident file does not carry
      # every span attribute the agent happened to record.
      #
      # `appsignal.request.payload` is a JSON string, parsed here so the model
      # reads a structure rather than an escaped blob.
      def request_details(span)
        attrs = span["span_attributes"] || {}
        tags  = attrs.select { |k, _| k.start_with?("appsignal.tag.") }
                     .transform_keys { |k| k.delete_prefix("appsignal.tag.") }
        {
          "action"       => span["action_name"],
          "revision"     => span["revision"],
          "status"       => span["status_message"],
          "payload"      => parse_maybe(attrs["appsignal.request.payload"]),
          "session_data" => parse_maybe(attrs["appsignal.request.session_data"]),
          "headers"      => attrs.select { |k, _| k.start_with?("http.request.header.") }
                                 .transform_keys { |k| k.delete_prefix("http.request.header.") },
          "tags"         => tags
        }.compact
      end

      # Step 4. The frames hang off the stacktrace_id the exception event
      # carries, not off the incident — see the class comment.
      def fetch_backtrace(app_id, span)
        event = Array(span["events.attributes"]).find { |a| a.is_a?(Hash) && a["appsignal.stacktrace_id"] }
        id    = event && event["appsignal.stacktrace_id"]
        return nil unless id

        data = graphql(<<~GQL, "appId" => app_id, "id" => id, "revision" => span["revision"])
          query B($appId: String!, $id: String!, $revision: String) {
            app(id: $appId) {
              backtrace(id: $id, revision: $revision) {
                original line column path method type
                code { line source }
              }
            }
          }
        GQL
        frames = data.dig("app", "backtrace")
        frames && !frames.empty? ? frames : nil
      rescue Error
        # A missing backtrace must not lose the payload we already have.
        nil
      end

      def parse_maybe(value)
        return nil if value.nil? || value.to_s.strip.empty?
        JSON.parse(value)
      rescue JSON::ParserError, TypeError
        value
      end

      # GraphQL takes the token ONLY as a query parameter — there is no header
      # form. That is why #scrub exists.
      def graphql(query, variables)
        uri = URI(GRAPHQL_URL)
        uri.query = URI.encode_www_form(token: @token)
        body = post(uri, { "query" => query, "variables" => variables })
        if (errors = body["errors"])
          raise Error, "AppSignal GraphQL error: #{Array(errors).map { |e| e["message"] }.join("; ")}"
        end
        body["data"] || {}
      end

      # The V2 API accepts a Bearer header, so the token never reaches a URL
      # here. Both V2 endpoints answer with a bare array of rows.
      def v2(path, payload)
        Array(post(URI("#{V2_URL}#{path}"), payload, bearer: true))
      end

      def post(uri, payload, bearer: false)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                              read_timeout: 30, open_timeout: 10) do |http|
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"]  = "application/json"
          req["Authorization"] = "Bearer #{@token}" if bearer
          req.body = JSON.generate(payload)
          http.request(req)
        end
        raise Error, "AppSignal returned HTTP #{res.code} for #{scrub(uri)}: #{scrub(res.body.to_s[0, 300])}" \
          unless res.is_a?(Net::HTTPSuccess)

        JSON.parse(res.body)
      rescue Error
        raise
      rescue JSON::ParserError
        raise Error, "AppSignal returned a non-JSON body for #{scrub(uri)}"
      rescue StandardError => e
        raise Error, "could not reach AppSignal at #{scrub(uri)}: #{scrub(e.message)}"
      end

      # The GraphQL token lives in the URL, so every error string built from a
      # URL — or from an exception whose message quotes one — has to be scrubbed
      # before it reaches chomp.log. This is the one real cost of GraphQL over a
      # header-authenticated API, and it is paid here, once, rather than trusted
      # to every call site.
      def scrub(text) = text.to_s.gsub(/token=[^&\s"]+/, "token=[redacted]")
    end
  end
end
