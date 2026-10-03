require "net/http"
require "uri"
require "json"

module OPilot
  module Clients
    # Reads one AppSignal exception incident: metadata, request payload, backtrace.
    # Four calls over GraphQL and V2 tracing, in a fixed order; the payload is only
    # in V2. See CLAUDE.md, appsignal.
    class AppSignal
      Error = Class.new(StandardError)

      GRAPHQL_URL = "https://appsignal.com/graphql".freeze
      V2_URL      = "https://appsignal.com/api/v2".freeze

      # How far back to look for the most recent trace of this digest.
      TRACE_WINDOW_DAYS = 30

      # The fields of one exception incident, for both the list and the single read.
      INCIDENT_FIELDS = <<~GQL.freeze
        number state severity namespace count
        exceptionName exceptionMessage firstBacktraceLine
        actionNames digests
        createdAt lastOccurredAt lastSampleOccurredAt
      GQL

      STATES = %w[OPEN CLOSED WIP].freeze
      ORDERS = %w[LAST TOTAL ID].freeze

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

      # One incident, written to incident.json, so this shape is the prompt's input.
      # Request and backtrace are best-effort: traces age out.
      def incident(app_id, number)
        incident = fetch_incident(app_id, number)
        raise Error, "AppSignal has no exception incident ##{number} on app #{app_id}" unless incident

        trace = fetch_trace(app_id, incident["digests"])
        incident.merge(
          "request"   => trace ? request_details(trace) : nil,
          "backtrace" => trace ? fetch_backtrace(app_id, trace) : nil
        ).compact
      end

      # One page of exception incidents: { "total", "incidents" }. A nil state
      # means every state. `offset` counts incidents, not pages. The API also
      # takes a timeframe, but it ignores it alone and returns nothing with
      # `exceptionQuery: TIMEFRAME`, so it is not offered.
      def exception_incidents(app_id, state: nil, order: "LAST", query: nil, namespace: nil, limit: 25, offset: 0)
        vars = { "appId" => app_id, "state" => state, "order" => order, "query" => query,
                 "namespaces" => namespace && [namespace], "limit" => limit, "offset" => offset }
        data = graphql(<<~GQL, vars)
          query L($appId: String!, $state: IncidentStateEnum, $order: IncidentOrderEnum, $query: String,
                  $namespaces: [String], $limit: Int, $offset: Int) {
            app(id: $appId) {
              paginatedExceptionIncidents(state: $state, order: $order, query: $query,
                                          namespaces: $namespaces, limit: $limit, offset: $offset) {
                total
                rows { #{INCIDENT_FIELDS} }
              }
            }
          }
        GQL
        page = data.dig("app", "paginatedExceptionIncidents") || {}
        { "total" => page["total"].to_i, "incidents" => page["rows"] || [] }
      end

      private

      # Step 1. `incident` is a union: an anomaly number returns an empty node, not an error.
      def fetch_incident(app_id, number)
        data = graphql(<<~GQL, "appId" => app_id, "number" => Integer(number))
          query I($appId: String!, $number: Int!) {
            app(id: $appId) {
              incident(incidentNumber: $number) {
                ... on ExceptionIncident { #{INCIDENT_FIELDS} }
              }
            }
          }
        GQL
        found = data.dig("app", "incident")
        found && found["number"] ? found : nil
      end

      # Step 2. `cursor` is required even on a first page; with DESC it gives the
      # most recent trace.
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

      # Step 3. Keeps only the request attributes; JSON strings are parsed for the model.
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

      # Step 4. Keyed by the span's stacktrace_id, not by the incident.
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

      # The GraphQL token is in the URL, so scrub every error string before it
      # reaches chomp.log.
      def scrub(text) = text.to_s.gsub(/token=[^&\s"]+/, "token=[redacted]")
    end
  end
end
