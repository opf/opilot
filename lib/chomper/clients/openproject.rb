module Chomper
  module Clients
    # OpenProject REST API client. Every endpoint the agent uses lives here;
    # callers never build URLs or call HTTP directly for OpenProject requests.
    class OpenProject
      SORT_UPDATED_AT = '[["updatedAt","desc"]]'.freeze

      def initialize(base_url, token)
        @base  = base_url
        @token = token
      end

      # Returns [code, response_hash]. Hits the global work-packages endpoint;
      # the project scope (one or many) is carried in filters_json as a
      # `project_id` filter (see Pull#filters_json), so a single sorted sweep
      # spans every selected project.
      def work_packages(filters_json:, page: 1, page_size: 50)
        filters = HTTP.encode_filters(filters_json)
        sort    = HTTP.encode_filters(SORT_UPDATED_AT)
        url = "#{@base}/api/v3/work_packages" \
              "?pageSize=#{page_size}&offset=#{page}&filters=#{filters}&sortBy=#{sort}"
        HTTP.get_json(url, token: @token)
      end

      def project_types(project_id)
        HTTP.get_json("#{@base}/api/v3/projects/#{project_id}/types", token: @token)
      end

      def project(project_id)
        HTTP.get_json("#{@base}/api/v3/projects/#{project_id}", token: @token)
      end

      # Returns [200, data] or raises HTTP::Error on non-200.
      def statuses
        HTTP.get_json!("#{@base}/api/v3/statuses", token: @token)
      end

      def project_versions(project_id)
        HTTP.get_json("#{@base}/api/v3/projects/#{project_id}/versions", token: @token)
      end

      def work_package(wp_id)
        HTTP.get_json("#{@base}/api/v3/work_packages/#{wp_id}", token: @token)
      end

      # Relations a work package participates in. Uses the global relations
      # endpoint with an `involved` filter (the per-WP route only 308-redirects,
      # which our Net::HTTP client won't follow). `involved_id` must be the
      # NUMERIC id — the involved filter coerces values to integers — and the
      # endpoint only returns relations whose BOTH sides are visible to the
      # token, so an unreachable related WP is filtered out server-side.
      def work_package_relations(involved_id)
        filters = HTTP.encode_filters(%Q([{"involved":{"operator":"=","values":["#{involved_id}"]}}]))
        HTTP.get_json("#{@base}/api/v3/relations?filters=#{filters}&pageSize=100", token: @token)
      end

      def work_package_activities(wp_id)
        HTTP.get_json("#{@base}/api/v3/work_packages/#{wp_id}/activities", token: @token)
      end

      def work_package_emoji_reactions(wp_id)
        HTTP.get_json("#{@base}/api/v3/work_packages/#{wp_id}/activities_emoji_reactions", token: @token)
      end

      def user(user_id)
        HTTP.get_json("#{@base}/api/v3/users/#{user_id}", token: @token)
      end

      def me
        HTTP.get_json("#{@base}/api/v3/users/me", token: @token)
      end

      def post_emoji_reaction(activity_id, reaction:)
        HTTP.patch_json(
          "#{@base}/api/v3/activities/#{activity_id}/emoji_reactions",
          { "reaction" => reaction },
          token: @token
        )
      end

      # Schema for one project/type pair — fields (incl. custom fields) depend on both.
      def work_package_schema(project_id, type_id)
        HTTP.get_json("#{@base}/api/v3/work_packages/schemas/#{project_id}-#{type_id}", token: @token)
      end

      # Posts a comment to a work package. Returns [code, response_hash].
      def post_activity(wp_id, comment:, internal: true)
        HTTP.post_json(
          "#{@base}/api/v3/work_packages/#{wp_id}/activities",
          { "comment" => { "raw" => comment }, "internal" => internal },
          token: @token
        )
      end
    end
  end
end
