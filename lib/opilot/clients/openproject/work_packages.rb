module OPilot
  module Clients
    module OpenProject
      # Work packages: the reads, and every write this client can make — all of
      # them land on a work package. There is no DELETE anywhere: a work
      # package can never be deleted, and nothing here may undo one.
      #
      # `notify` is a QUERY parameter, not a body field (the API reads
      # params[:notify] != "false"). Without it a generated tree of tasks mails
      # every watcher, so every writer here defaults it off.
      module WorkPackages
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
                          sort_by: Query::SORT_UPDATED_AT, include_subprojects: true)
          collection("work_packages", filters_json: filters_json, page: page, page_size: page_size,
                                      sortBy: sort_by, includeSubprojects: include_subprojects)
        end

        def work_package(wp_id)
          get("work_packages/#{wp_id}")
        end

        def work_package_activities(wp_id)
          get("work_packages/#{wp_id}/activities")
        end

        def work_package_emoji_reactions(wp_id)
          get("work_packages/#{wp_id}/activities_emoji_reactions")
        end

        # Relations a work package participates in. Uses the global relations
        # endpoint with an `involved` filter (the per-WP route only 308-redirects,
        # which our Net::HTTP client won't follow). `involved_id` must be the
        # NUMERIC id — the involved filter coerces values to integers — and the
        # endpoint only returns relations whose BOTH sides are visible to the
        # token, so an unreachable related WP is filtered out server-side.
        def work_package_relations(involved_id)
          get("relations", filters: Query.filter("involved", "=", involved_id), pageSize: 100)
        end

        # PRs the GitHub integration linked to a work package. Needs
        # :show_github_content and the project's `github` module, so a 403 or 404
        # is a normal answer. `merged` is a boolean; `state` is open/closed/deployed.
        def work_package_github_pull_requests(wp_id)
          get("work_packages/#{wp_id}/github_pull_requests")
        end

        # Who may be assigned to this work package. Needs :edit_work_packages.
        def work_package_available_assignees(wp_id)
          get("work_packages/#{wp_id}/available_assignees")
        end

        # The schema for one (project, type) pair: every field's key, display
        # name, `required`, `writable` and allowed values. Custom fields differ
        # per pair, so this is how "Customer" becomes `customField12`. The route
        # composes the two ids with a dash, so both must be NUMERIC.
        def work_package_schema(project_id, type_id)
          get("work_packages/schemas/#{project_id}-#{type_id}")
        end

        # --- writes ---

        # Create a work package. `payload` is the full v3 body — subject,
        # description, and _links (type, project, parent). Returns [code, hash].
        def create_work_package(payload, notify: false)
          post("work_packages", payload, notify: notify)
        end

        # Ask whether a create payload would be accepted, WITHOUT creating anything.
        #
        # This is the same validation the create runs: the form endpoint drives
        # `WorkPackages::SetAttributesService` (API::Utilities::Endpoints::Bodied
        # deduces it) and simply does not save. So a payload the form accepts is a
        # payload the create accepts, and the defaults the form fills in are the
        # ones the create fills in too — which is why callers read the errors and
        # send their own payload unchanged.
        #
        # It answers **200 even when the payload is invalid**: validation errors are
        # this endpoint's normal output (`Endpoints::Form#success?` accepts a call
        # whose every error is a 422). So the answer is `_embedded.validationErrors`
        # — keyed by property — and never the status code. `_embedded.schema` says
        # which fields are `required` and what they allow, per project AND type.
        def create_work_package_form(payload)
          post("work_packages/form", payload)
        end

        # Update a work package. v3 uses optimistic locking: the PATCH must carry
        # the current lockVersion or it 409s. Callers pass only the fields they
        # want changed; this fetches the current lockVersion, injects it, and on a
        # 409 (someone edited between our read and our write) refetches and
        # retries exactly once before giving up — per the API's own guidance that
        # a conflict is retry-once-then-escalate, not an error. Returns
        # [code, hash]; a persistent 409 is returned for the caller to escalate.
        def update_work_package(wp_id, payload, notify: false)
          write = ->(locked) { patch("work_packages/#{wp_id}", locked, notify: notify) }
          response = with_lock_version(wp_id, payload, &write)
          response.code == 409 ? with_lock_version(wp_id, payload, &write) : response
        end

        # Ask whether an update would be accepted, WITHOUT saving it — the dry run
        # of #update_work_package, as #create_work_package_form is of a create.
        # Same rules: it answers 200 for an invalid payload, so read
        # `_embedded.validationErrors`. The update contract checks lockVersion
        # too, so the current one is injected here the same way.
        def update_work_package_form(wp_id, payload)
          with_lock_version(wp_id, payload) { |locked| post("work_packages/#{wp_id}/form", locked) }
        end

        # Yields the payload with the CURRENT lockVersion, re-read before each
        # attempt — a stale one is what produced the 409. A work package that
        # cannot be read answers with that read's code, so a 404 or 403 does
        # not pass for an edit conflict.
        def with_lock_version(wp_id, payload)
          read = work_package(wp_id)
          return read unless read.ok?
          return Response.new(409, nil, read.request) unless read.body["lockVersion"]
          yield payload.merge("lockVersion" => read.body["lockVersion"])
        end
        private :with_lock_version

        # Relate two work packages — `create wp` links the work package it creates
        # back to the one whose comment asked for it.
        #
        # The URL is the PER-WORK-PACKAGE route, not the global /api/v3/relations
        # #work_package_relations reads: that collection has index, show, patch and
        # delete, and no POST. Only the GET on this route is the 308 that
        # method's comment describes.
        #
        # Both ids must be NUMERIC (the route param is typed Integer, and the `to`
        # link addresses a work-package id), so a semantic id must be resolved
        # first. The route work package becomes the relation's `from` — the
        # endpoint sets it — so the payload names only `to`.
        #
        # `relates` is the one symmetric type and carries no reverse in
        # Relation::TYPES, so OpenProject stores the direction as written.
        def create_relation(from_id, to_id, type: "relates", notify: false)
          post(
            "work_packages/#{from_id}/relations",
            { "type" => type, "_links" => { "to" => Href.link(Href.work_package(to_id)) } },
            notify: notify
          )
        end

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
          post("work_packages/#{wp_id}/activities",
               { "comment" => { "raw" => Helpers.demote_headings(comment) }, "internal" => internal })
        end

        # Acknowledge a comment before opilot starts working — the same operation
        # as Clients::GitHub#react, named to match. `reaction:` is the wire field.
        # Note the verb: this endpoint is a PATCH, surprising for a create.
        def react(activity_id, reaction:)
          patch("activities/#{activity_id}/emoji_reactions", { "reaction" => reaction })
        end
      end
    end
  end
end
