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
      # spans every selected project. includeSubprojects=true expands each
      # selected project with its visible descendants, so scanning a parent
      # project also covers its child projects' work packages.
      def work_packages(filters_json:, page: 1, page_size: 50)
        filters = HTTP.encode_filters(filters_json)
        sort    = HTTP.encode_filters(SORT_UPDATED_AT)
        url = "#{@base}/api/v3/work_packages" \
              "?pageSize=#{page_size}&offset=#{page}&filters=#{filters}&sortBy=#{sort}&includeSubprojects=true"
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

      # --- Documents (product-development intake) -------------------------
      #
      # The v3 Documents API is provided by the `documents` project module, so
      # it 404s unless that module is enabled on the project and the token
      # carries :view_documents. Its query supports project/document/title/type
      # filters but NOT updatedAt, so any "since" narrowing is client-side.

      # The project filter coerces its values to integers, so a project
      # IDENTIFIER ("my-project") does not raise — it matches nothing, and the
      # sweep silently comes back empty. Resolve to the numeric id first.
      def documents(project_id, page: 1, page_size: 100)
        code, numeric = project_numeric_id(project_id)
        return [code, nil] unless numeric

        filters = HTTP.encode_filters(%Q([{"project":{"operator":"=","values":["#{numeric}"]}}]))
        HTTP.get_json("#{@base}/api/v3/documents?pageSize=#{page_size}&offset=#{page}&filters=#{filters}",
                      token: @token)
      end

      # Numeric id for a project given either its id or its identifier. Returns
      # [code, id], with id nil when the project could not be read, so callers
      # keep mapping 403/404 to their own wording. Memoized per client: the
      # documents flow asks repeatedly and a project's id cannot change under a
      # running command. /api/v3/projects/<x> accepts both spellings, which is
      # why the identifier gets this far in the first place.
      def project_numeric_id(project_id)
        return [200, project_id.to_i] if project_id.to_s.match?(/\A\d+\z/)

        @project_numeric_ids ||= {}
        cached = @project_numeric_ids[project_id.to_s]
        return cached if cached

        code, body = project(project_id)
        id = body && body["id"]
        return [code, nil] unless code == 200 && id
        @project_numeric_ids[project_id.to_s] = [200, id]
      end

      # One document, with links embedded — carries title, the formattable
      # description, created_at/updated_at, and the project link that
      # Intake uses to verify a --doc-id belongs to the named project.
      def document(document_id)
        HTTP.get_json("#{@base}/api/v3/documents/#{document_id}", token: @token)
      end

      # Attachment metadata for a document: fileName, contentType, fileSize and
      # _links.downloadLocation for each. The content itself is fetched with
      # #download_attachment, since it is binary and behind a redirect.
      def document_attachments(document_id)
        HTTP.get_json("#{@base}/api/v3/documents/#{document_id}/attachments?pageSize=100", token: @token)
      end

      # Raw attachment bytes. Returns [code, bytes]; the download location 302s
      # to wherever the file actually lives, which HTTP.get_binary follows.
      def download_attachment(download_url)
        HTTP.get_binary(download_url, token: @token)
      end

      # --- Work-package writes --------------------------------------------
      #
      # `notify` is a QUERY parameter, not a body field (the API reads
      # params[:notify] != "false"). Without it a generated tree of tasks mails
      # every watcher, so both writers default it off.

      # Create a work package. `payload` is the full v3 body — subject,
      # description, and _links (type, project, parent). Returns [code, hash].
      def create_work_package(payload, notify: false)
        HTTP.post_json("#{@base}/api/v3/work_packages?notify=#{notify}", payload, token: @token)
      end

      # Update a work package. v3 uses optimistic locking: the PATCH must carry
      # the current lockVersion or it 409s. Callers pass only the fields they
      # want changed; this fetches the current lockVersion, injects it, and on a
      # 409 (someone edited between our read and our write) refetches and
      # retries exactly once before giving up — per the API's own guidance that
      # a conflict is retry-once-then-escalate, not an error. Returns
      # [code, hash]; a persistent 409 is returned for the caller to escalate.
      def update_work_package(wp_id, payload, notify: false)
        url = "#{@base}/api/v3/work_packages/#{wp_id}?notify=#{notify}"
        code, body = patch_with_lock(url, wp_id, payload)
        code == 409 ? patch_with_lock(url, wp_id, payload) : [code, body]
      end

      # The current lockVersion, or nil when the work package can't be read.
      def lock_version(wp_id)
        code, body = work_package(wp_id)
        code == 200 ? body["lockVersion"] : nil
      end

      # Re-reads the lockVersion immediately before each attempt — that freshness
      # is the whole point, since a stale one is what produced the 409.
      def patch_with_lock(url, wp_id, payload)
        version = lock_version(wp_id)
        return [409, nil] unless version
        HTTP.patch_json(url, payload.merge("lockVersion" => version), token: @token)
      end
      private :patch_with_lock

      # Posts a comment to a work package. Returns [code, response_hash].
      #
      # Headings are demoted to bold on the way out (Helpers.demote_headings):
      # the activity tab is a narrow column, and this is the one funnel every
      # comment passes through — Claude's replies, a posted plan, the pd links.
      def post_activity(wp_id, comment:, internal: true)
        HTTP.post_json(
          "#{@base}/api/v3/work_packages/#{wp_id}/activities",
          { "comment" => { "raw" => Helpers.demote_headings(comment) }, "internal" => internal },
          token: @token
        )
      end
    end
  end
end
