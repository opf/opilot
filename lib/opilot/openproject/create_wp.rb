module OPilot
  module OpenProject
    # `@opilot create wp <what>`. Every guard here exists because a work package
    # can never be deleted. See CLAUDE.md, `:create_wp`.
    # `reply` (owned by Agent) posts to the commenter with the trigger's visibility.
    class CreateWp
      include Helpers

      Resource = Clients::OpenProject::Resource

      # The cap on one request. Enforced here, because a prompt limit drifts.
      MAX = 5

      # Why the command is off. Shared with Matrix::Agent, which answers it every time.
      DISABLED_NOTE = "I do not create work packages on this instance. The administrator must set " \
                      "OPILOT_ALLOWED_OP_USER_IDS first, because a work package can never be deleted.".freeze

      # Off without an allowlist. With one, Pull drops every unlisted trigger,
      # so each create that reaches here is from a listed user.
      def self.enabled?(ctx)
        ctx.allowed_op_user_ids.any?
      end

      def initialize(ctx, api:, harness:, pull:, reply:)
        @ctx     = ctx
        @api     = api
        @harness = harness
        @pull    = pull
        @reply   = reply
      end

      def run(intent)
        st = state_for(intent.item_id, intent.subject, intent.type)
        return note_create_wp_disabled(st) unless self.class.enabled?(@ctx)

        # A re-fired trigger re-reports its records (even a partial set), finishes
        # failed links, and creates nothing more.
        records = ensure_links(st, intent.comment_at)
        if records.any?
          @reply.(st.item_id, already_created_note(records))
          return
        end

        request = intent.text.to_s.strip
        if request.empty?
          @reply.(st.item_id,
            "Tell me what to create. Write `create wp` and then what the new work package " \
            "is about — the person or the suggestion in this thread."
          )
          return
        end

        wp = fetch_source_wp(st)
        return unless wp
        project = fetch_project_for_create(st, wp["project_id"])
        return unless project
        types = project_type_names(wp["project_id"])

        drafts = write_work_packages(st, request, project["name"], types, related_ref(st))
        return unless drafts

        create_and_report(st, intent, drafts, wp, types)
      rescue StandardError => e
        # Not re-raised: #handle_and_ack would only log it again.
        log_script "create wp failed for #{wp_label(intent.item_id)}: #{e.class}: #{e.message}"
        @reply.(intent.item_id,
                "I could not create the work package. The reason is in my log: #{e.message}")
      end

      private

      # Once per work package, not per comment, so nobody can fill the activity tab.
      def note_create_wp_disabled(st)
        data = Helpers.safe_json_read(st.item_file) || {}
        return if data["create_wp_refusal_noted_at"]

        code = @reply.(st.item_id, DISABLED_NOTE)
        return unless code == 201

        data["create_wp_refusal_noted_at"] = Time.now.utc.iso8601
        Helpers.write_item(st.item_file, data)
      end

      # Fetched fresh: item.json has no project, and its id may be semantic while
      # the relation route takes only numeric ids. nil (answered) on failure.
      def fetch_source_wp(st)
        res = @api.work_package(st.item_id)
        unless res.code == 200 && res.body
          @reply.(st.item_id, "I could not read this work package from the API (HTTP #{res.code}), " \
                              "so I created nothing.")
          return nil
        end
        project_id = Resource.link_id(res.body, "project")
        if project_id.to_s.empty?
          @reply.(st.item_id, "I could not tell which project this work package belongs to, " \
                              "so I created nothing.")
          return nil
        end
        { "numeric_id" => res.body["id"].to_s, "project_id" => project_id }
      end

      # A second GET: the createWorkPackage links render only on the project itself.
      # Checked before the LLM call, so a missing permission costs no draft.
      def fetch_project_for_create(st, project_id)
        res = @api.project(project_id)
        unless res.code == 200 && res.body
          @reply.(st.item_id, "I could not read project #{project_id} (HTTP #{res.code}), " \
                              "so I created nothing.")
          return nil
        end
        unless Resource.create_wp_allowed?(res.body)
          @reply.(st.item_id,
            "I cannot create work packages in #{res.body["name"]}. My OpenProject token has no " \
            "`add_work_packages` permission there. Ask an administrator for it."
          )
          return nil
        end
        res.body
      end

      # Best-effort: an empty list lets OpenProject pick the default type.
      def project_type_names(project_id)
        res = @api.project_types(project_id)
        return [] unless res.code == 200 && res.body
        Resource.type_list(res.body)
      rescue StandardError => e
        log_script "Warning: could not list types for project #{project_id} (#{e.message})."
        []
      end

      # One call for all drafts, so no two drafts can duplicate each other.
      # Returns the blocks, or nil once answered. A retry is safe: nothing exists yet.
      def write_work_packages(st, request, project_name, types, related, retry_bad: true, format_note: nil)
        log_script "Writer: drafting work packages from #{wp_label(st.item_id)} — #{request}"
        prompt = Prompts::WpWriter.create_wp(item_id: st.item_id, subject: st.subject,
                                   item: container_path(st.item_file), request: request,
                                   project: project_name, types: Helpers.types_for_prompt(types),
                                   max: MAX, related: related, format_note: format_note)
        reply = llm(:wp_writer, prompt, session_file: st.session_file).to_s
        # Text before the last `ANSWER:` is scratch; no marker reads the whole text.
        answer = Helpers.after_marker(reply, "ANSWER")

        if (questions = Helpers.needs_info(answer))
          log_script "create wp NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
          @reply.(st.item_id, "I need more information before I create a work package:\n\n#{questions}")
          return nil
        end

        drafts = Helpers.parse_work_packages(answer)
        # Over the cap is a scope problem; a retry would give the same list.
        if drafts.length > MAX
          log_script "#{wp_label(st.item_id)} — the writer produced #{drafts.length} work packages; " \
                     "the cap is #{MAX}, so nothing was created."
          @reply.(st.item_id,
            "That request comes to #{drafts.length} work packages, and I create at most " \
            "#{MAX} at a time, because a work package can never be deleted. " \
            "I created nothing. Ask me again for a smaller set."
          )
          return nil
        end
        return drafts if drafts.any?
        if retry_bad
          # Name the miss, or the identical prompt repeats it.
          return write_work_packages(st, request, project_name, types, related,
                                     retry_bad: false, format_note: Helpers.wp_format_miss(answer, many: true))
        end

        log_script "#{wp_label(st.item_id)} — the writer produced no usable work-package block twice."
        @reply.(st.item_id, "I could not draft the work package. Ask me again, and say in one " \
                            "sentence what it is about.")
        nil
      rescue Harness::Error => e
        # The output limit ran out before a draft. Not retried: the same prompt
        # spends the same budget.
        raise unless e.message.to_s.include?("length")
        log_script "#{wp_label(st.item_id)} — the draft run hit the model's output limit (#{e.message})."
        @reply.(st.item_id,
          "I ran out of writing space before I finished the draft, so I created nothing. " \
          "Ask me again with a shorter, more specific request."
        )
        nil
      end

      # Preflight all, then POST, record, link, report. Each step must survive the
      # next one failing. The whole set is preflighted first: half a tree is worse than none.
      def create_and_report(st, intent, drafts, wp, types)
        payloads = drafts.map { |draft| [draft, create_wp_payload(st, draft, wp["project_id"], types)] }
        return unless payloads_accepted?(st, payloads, types)

        created   = []
        failed    = []
        last_code = nil
        payloads.each do |draft, payload|
          res = @api.create_work_package(payload)
          last_code = res.code
          unless res.code == 201 && res.body
            log_script "create wp failed for #{wp_label(st.item_id)} — HTTP #{res.code} on #{payload["subject"].inspect}"
            failed << draft
            next
          end
          record = record_created_wp(st, intent, wp, res.body, draft: draft)
          created << record
          log_script "Created #{wp_label(record["id"])} from #{wp_label(st.item_id)}"
          record_progress(st.item_id, "-", "created-wp:#{record["id"]}")
        end

        if created.empty?
          subject = failed.length == 1 ? "the work package" : "any of the #{failed.length} work packages"
          @reply.(st.item_id, "I could not create #{subject} (HTTP #{last_code}). " \
                              "The response is in my log.")
          return
        end

        # All records for the comment, including an earlier partial create.
        @reply.(st.item_id, created_note(ensure_links(st, intent.comment_at), failed))
      end

      # `all?` stops at the first rejection: one rejection creates nothing.
      def payloads_accepted?(st, payloads, types)
        many = payloads.length > 1
        payloads.all? { |_draft, payload| payload_accepted?(st, payload, types, many: many) }
      end

      # Preflight through the create form. Never fill a required custom field or
      # switch the type here: only a person knows the value. See CLAUDE.md, `:create_wp`.
      def payload_accepted?(st, payload, types, many: false)
        form = @api.create_work_package_form(payload)
        # A form that did not run (403, 404, HTML) does not block the create.
        log_script "#{wp_label(st.item_id)} — the create form answered HTTP #{form.code}; creating without it." \
          unless form.form_answered?
        errors = form.validation_errors
        return true unless errors

        log_script "#{wp_label(st.item_id)} — the project rejects #{payload["subject"].inspect}: " \
                   "#{errors.keys.join(", ")}"
        @reply.(st.item_id, required_fields_note(errors, types,
                                                 subject: many ? payload["subject"] : nil))
        false
      end

      # Quotes the API's messages, which use the labels a person sees. `subject`
      # names the rejected draft when the request asked for several.
      def required_fields_note(errors, types, subject: nil)
        reasons = errors.map { |field, error| "- #{error["message"]} (`#{field}`)" }.join("\n")
        opening = if subject
                    "I cannot create #{subject.inspect}, so I created none of them."
                  else
                    "I cannot create the work package."
                  end
        note = +"#{opening} This project needs values I must not invent:\n\n#{reasons}\n\n" \
                "Create the work package in OpenProject, and I can work on it there."
        # Required-ness is per type, so another type may need none of this.
        names = types.map { |t| t["name"] }.reject(&:empty?)
        if names.length > 1
          note << " You can also ask me again and name a different type — this project has: " \
                  "#{names.join(", ")}."
        end
        note
      end

      def create_wp_payload(st, draft, project_id, types)
        Clients::OpenProject::Payload.work_package(
          project: project_id, type: chosen_type(st, draft, types),
          subject: draft["subject"], description: create_wp_description(st, draft)
        )
      end

      # The named type, else the project's first, stated explicitly so it shows in
      # the payload and the log. nil only when the type list was unreadable.
      def chosen_type(st, draft, types)
        named = Resource.find_named(types, draft["type"])
        return named if named

        fallback = types.first
        log_script "create wp for #{wp_label(st.item_id)} — type #{draft["type"].inspect} is not on this " \
                   "project; using #{fallback ? fallback["name"].inspect : "the API's default"}."
        fallback
      end

      # Opens with a backlink, the only one left when the relation fails.
      def create_wp_description(st, draft)
        origin = "Created by opilot from the discussion in " \
                 "[#{wp_label(st.item_id)}](#{Helpers.wp_url(@ctx, st.item_id)})."
        "#{origin}\n\n#{draft["description"]}".strip
      end

      # ── created_wps.json, keyed by the trigger's comment_at ───────────────────
      # Each record is written on its 201, before the link and the reply.

      def created_wps(st)
        Helpers.safe_json_read(st.created_wps_file) || []
      end

      def records_for(records, comment_at)
        records.select { |r| r["comment_at"] == comment_at.to_s }
      end

      # `link_wanted` is stored, never inferred later from the set's size.
      # `asked_type` lets the report name a substituted type.
      def record_created_wp(st, intent, wp, body, draft:)
        record = { "comment_at"        => intent.comment_at.to_s,
                   "id"                => Resource.display_id(body),
                   "numeric_id"        => body["id"].to_s,
                   "source_numeric_id" => wp["numeric_id"],
                   "subject"           => body["subject"].to_s,
                   "url"               => Helpers.wp_url(@ctx, Resource.display_id(body)),
                   "type"              => body.dig("_links", "type", "title").to_s,
                   "asked_type"        => draft["type"].to_s,
                   "link_wanted"       => draft["link"] == "child" ? "parent" : "relates",
                   "link"              => nil,
                   "related"           => false,
                   "created_at"        => Time.now.utc.iso8601 }
        records = created_wps(st) << record
        Helpers.write_json_atomic(st.created_wps_file, records, "created_wps", pretty: true)
        record
      end

      # Links each unlinked record of the comment and returns all of them ([] if none).
      # Best-effort: a link needs permissions the create does not.
      def ensure_links(st, comment_at)
        records = created_wps(st)
        mine    = records_for(records, comment_at)
        return [] if mine.empty?

        linked = mine.reject { |r| r["related"] }.count { |record| link_record(st, record) }
        Helpers.write_json_atomic(st.created_wps_file, records, "created_wps", pretty: true) if linked.positive?
        mine
      end

      # The asked shape, falling back to `relates`. Returns whether the record changed.
      # A legacy record has no `link_wanted` and reads as "relates".
      def link_record(st, record)
        wanted = record["link_wanted"] == "parent" ? "parent" : "relates"
        return true if record_linked!(record, wanted, set_link(record, wanted))
        return false unless wanted == "parent"

        log_script "#{wp_label(st.item_id)} — could not make #{wp_label(record["id"])} a child of it; " \
                   "relating it instead."
        record_linked!(record, "relates", set_link(record, "relates"))
      end

      def record_linked!(record, shape, code)
        return false unless [200, 201].include?(code)
        record["related"] = true
        record["link"]    = shape
        true
      end

      # Returns the HTTP code, or nil when the call raised. The new work package is `from`.
      def set_link(record, shape)
        source = record["source_numeric_id"]
        res = @api.link_work_package(record["numeric_id"], source, as: shape.to_sym)
        log_script "#{wp_label(record["id"])} — #{shape} link to #{wp_label(source)} answered HTTP #{res.code}." \
          unless [200, 201].include?(res.code)
        res.code
      rescue StandardError => e
        log_script "#{wp_label(record["id"])} — could not set the #{shape} link to #{wp_label(source)} " \
                   "(#{e.message})."
        nil
      end

      # Never a bare "#123": in OpenProject the id alone is not a link.
      def created_wp_link(record)
        subject = record["subject"].to_s.strip
        label   = subject.empty? ? wp_label(record["id"]) : "#{wp_label(record["id"])} #{subject}"
        "[#{label}](#{record["url"]})"
      end

      # ── what the reader is told (composed in Ruby, so it cannot drift) ────────

      # `failed` drafts must be asked for again on their own.
      def created_note(records, failed = [])
        note = +if records.length == 1
                  "I created #{created_wp_link(records.first)} from this thread.#{single_notes(records.first)}"
                else
                  "I created #{records.length} work packages from this thread:" \
                  "\n\n#{records.map { |r| created_line(r) }.join("\n")}"
                end
        return note if failed.empty?

        subjects = failed.map { |d| d["subject"].to_s.strip.inspect }.join(", ")
        note << "\n\nI could not create #{subjects} — the reason is in my log. Asking me again " \
                "here creates nothing more, so ask for #{failed.length == 1 ? "that one" : "those"} on its own."
      end

      def already_created_note(records)
        if records.length == 1
          return "I already created #{created_wp_link(records.first)} for that request." \
                 "#{single_notes(records.first)}"
        end

        "I already created these for that request:\n\n#{records.map { |r| created_line(r) }.join("\n")}"
      end

      # Always states the shape: the reader cannot tell child from peer by the count.
      def single_notes(record)
        notes = +""
        if !record["related"]
          notes << if record["link_wanted"] == "parent"
                     " I meant it as a child of this one, but I could not set the parent — set it by hand."
                   else
                     " I could not link the two work packages, so add the relation by hand."
                   end
        elsif record["link"] == "parent"
          notes << " It is a child of this work package."
        elsif record["link_wanted"] == "parent"
          notes << " I meant it as a child, but I could not set a parent here, so I related it instead."
        end
        asked, got = substituted_type(record)
        notes << " This project has no #{asked} type, so I used #{got}." if asked
        notes
      end

      def created_line(record)
        "- #{created_wp_link(record)} — #{link_words(record)}#{type_words(record)}"
      end

      # Reads `related` first: a legacy record has no `link`.
      def link_words(record)
        unless record["related"]
          return record["link_wanted"] == "parent" ? "not linked — set the parent by hand" : "not linked — relate it by hand"
        end
        return "child of this work package" if record["link"] == "parent"

        record["link_wanted"] == "parent" ? "related; I could not make it a child" : "related"
      end

      # A substituted type is invisible in a list of links, so it is named there.
      def type_words(record)
        asked, got = substituted_type(record)
        asked ? "; #{got}, not #{asked}" : ""
      end

      # [asked, got] when the instance stored another type than the block named, else nil.
      def substituted_type(record)
        asked = record["asked_type"].to_s.strip
        got   = record["type"].to_s.strip
        return nil if asked.empty? || got.empty? || asked.casecmp?(got)
        [asked, got]
      end
    end
  end
end
