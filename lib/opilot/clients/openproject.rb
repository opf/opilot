module OPilot
  module Clients
    # OpenProject REST API client. Every endpoint the agent uses lives here;
    # callers never build URLs or call HTTP directly for OpenProject requests.
    class OpenProject
      SORT_UPDATED_AT = '[["updatedAt","desc"]]'.freeze

      def initialize(base_url, token)
        @base  = base_url
        @token = token
      end

      # The `filters` query value: a JSON array of single-key objects. Values are
      # stringified because the encoded string identifies the request — an
      # Integer here would silently move every URL built through this.
      def self.filter(field, operator, *values)
        JSON.generate([{ field.to_s => { "operator" => operator.to_s,
                                         "values" => values.flatten.map(&:to_s) } }])
      end

      # Returns [code, response_hash]. Hits the global work-packages endpoint;
      # op-agent's poll scopes it with a `comment` filter keyed on opilot's own
      # display name (see Pull#mention_filter_json) rather than any project
      # scope — the API token's own project access is the trust boundary.
      #
      # The sort and subproject values are that poll's policy, not API facts, so
      # they are defaults rather than constants: it stops at the first WP older
      # than its scan floor, and includeSubprojects expands a project-scoped
      # filter with its visible descendants (harmless when none is sent).
      def work_packages(filters_json:, page: 1, page_size: 50,
                        sort_by: SORT_UPDATED_AT, include_subprojects: true)
        filters = HTTP.encode_filters(filters_json)
        sort    = HTTP.encode_filters(sort_by)
        url = "#{@base}/api/v3/work_packages" \
              "?pageSize=#{page_size}&offset=#{page}&filters=#{filters}&sortBy=#{sort}" \
              "&includeSubprojects=#{include_subprojects}"
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
        filters = HTTP.encode_filters(self.class.filter("involved", "=", involved_id))
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

      # Acknowledge a comment before opilot starts working — the same operation
      # as Clients::GitHub#react, named to match. `reaction:` is the wire field.
      # Note the verb: this endpoint is a PATCH, surprising for a create.
      def react(activity_id, reaction:)
        HTTP.patch_json(
          "#{@base}/api/v3/activities/#{activity_id}/emoji_reactions",
          { "reaction" => reaction },
          token: @token
        )
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

        filters = HTTP.encode_filters(self.class.filter("project", "=", numeric))
        HTTP.get_json("#{@base}/api/v3/documents?pageSize=#{page_size}&offset=#{page}&filters=#{filters}",
                      token: @token)
      end

      # --- Derived ----------------------------------------------------------
      #
      # A convenience over an endpoint rather than one itself. It lives here
      # because the documents flow above is its only external caller.

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
      #
      # The token rides along ONLY for a URL on this instance. get_binary already
      # drops it from hop 2 onward; hop 1 needs the same rule, because
      # `downloadLocation` is a direct presigned URL on S3-backed storage and
      # `op doc download` takes it from a caller. Withheld, not refused, so the
      # presigned shape keeps working.
      def download_attachment(download_url)
        HTTP.get_binary(download_url, token: on_this_instance?(download_url) ? @token : nil)
      end

      # Whether a URL points at the instance this client is configured for —
      # scheme, host and port all matching. A URL that cannot be parsed is not.
      def on_this_instance?(url)
        given = URI(url.to_s)
        base  = URI(@base.to_s)
        given.scheme == base.scheme && given.host == base.host && given.port == base.port
      rescue URI::InvalidURIError
        false
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
      private :lock_version

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
      # OpenProject models a comment as an activity, but this only ever creates a
      # comment, and every layer above already calls the returned id a comment id.
      # Named to match Clients::GitHub#add_issue_comment.
      #
      # Headings are demoted to bold on the way out (Helpers.demote_headings):
      # the activity tab is a narrow column, and this is the one funnel every
      # comment passes through — the LLM's replies, a posted plan, the pd links.
      def add_comment(wp_id, comment:, internal: true)
        HTTP.post_json(
          "#{@base}/api/v3/work_packages/#{wp_id}/activities",
          { "comment" => { "raw" => Helpers.demote_headings(comment) }, "internal" => internal },
          token: @token
        )
      end
    end
  end
end
