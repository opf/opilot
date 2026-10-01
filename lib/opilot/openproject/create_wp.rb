module OPilot
  module OpenProject
    # `@opilot create wp <what>` — split something out of this thread into its own
    # work package, or several.
    #
    # Every guard here stands on one fact: a work package CANNOT BE DELETED. The
    # API client has no DELETE verb anywhere, so nothing downstream can undo a
    # wrong or duplicate create. Hence the allowlist requirement, the idempotency
    # record written the instant the POST succeeds, the NEEDS_INFO gate in the
    # prompt, and the permission preflight before any LLM call.
    #
    # Unlike every other handler, this one answers its own failures on the work
    # package (see #handle_and_ack, which stays silent by design): a reader who
    # asked for a work package is waiting for a link, and silence reads as a
    # broken bot.
    #
    # Agent owns the reply: `reply` posts a note addressed to the commenter, with
    # the trigger's visibility.
    class CreateWp
      include Helpers

      Resource = Clients::OpenProject::Resource

      # How many work packages one request may create. Stated in the prompt and
      # enforced HERE, because a prompt limit drifts and a work package can never
      # be deleted: "create one for every suggestion in this thread" must not be
      # able to mint twenty rows nobody can remove. Five also sits well inside one
      # output budget — see Prompts::WpWriter.create_wp on why a cut-off answer is the
      # failure mode to fear.
      MAX = 5

      # Why the command is off. Shared with Matrix::Agent, which answers it every time.
      DISABLED_NOTE = "I do not create work packages on this instance. The administrator must set " \
                      "OPILOT_ALLOWED_OP_USER_IDS first, because a work package can never be deleted.".freeze

      # Whether `create wp` runs at all. It needs a non-empty allowlist, and that is
      # not a style choice: a work package can never be deleted, and with no
      # allowlist every user who can comment could mint them without limit.
      #
      # It also makes the allowlist gate unconditional for this command —
      # OpenProject::Pull#intent_from_comments drops a non-allowlisted trigger whenever a list
      # exists, so every create request that reaches here is from a listed user.
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

        # Created from this very comment already? Re-report them, and finish any
        # link that was the part that failed. This is what stops a re-fired
        # trigger — a crash before the ack, the same comment posted twice — from
        # minting a second set of work packages for one request. It reports every
        # record for the comment, including after a PARTIAL create: the ones that
        # landed are the answer, and asking again creates nothing more.
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
        # Answered here, not re-raised: #handle_and_ack would only log it a second
        # time, and it acks either way.
        log_script "create wp failed for #{wp_label(intent.item_id)}: #{e.class}: #{e.message}"
        @reply.(intent.item_id,
                "I could not create the work package. The reason is in my log: #{e.message}")
      end

      private

      # Say once per work package that the command is switched off. Once, not once
      # per comment, for OpenProject::Pull#note_refused_trigger's reason: a reply is the one
      # thing this path can be made to produce, and a per-comment answer would let
      # anyone fill the activity tab.
      def note_create_wp_disabled(st)
        data = Helpers.safe_json_read(st.item_file) || {}
        return if data["create_wp_refusal_noted_at"]

        code = @reply.(st.item_id, DISABLED_NOTE)
        return unless code == 201

        data["create_wp_refusal_noted_at"] = Time.now.utc.iso8601
        Helpers.write_item(st.item_file, data)
      end

      # The source work package, fetched FRESH: item.json caches no project, and the
      # cached id may be semantic ("PROJ-123") while the relation endpoint takes
      # only numeric ids. Returns nil (having answered) when it cannot be read.
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

      # The project resource, and the permission check on it. A SECOND GET on
      # purpose: the work package carries only a link stub for its project, and the
      # createWorkPackage links this checks are rendered on the project itself.
      # Asked before the LLM call, so a token without :add_work_packages costs a
      # request rather than a whole draft.
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

      # The types this project really offers, so the draft cannot name one that does
      # not exist. Best-effort: an empty list only means the runner lets OpenProject
      # pick the project's default type.
      def project_type_names(project_id)
        res = @api.project_types(project_id)
        return [] unless res.code == 200 && res.body
        Resource.type_list(res.body)
      rescue StandardError => e
        log_script "Warning: could not list types for project #{project_id} (#{e.message})."
        []
      end

      # One LLM call for every work package the request asks for, on the work
      # package's own session (it already holds the thread). Returns the parsed
      # blocks, or nil when the answer was NEEDS_INFO, over the cap, or unusable —
      # each already answered on the work package.
      #
      # ONE call whatever the count, because N blocks cost the same as one and a
      # call per work package would not see the others: two of them could write the
      # same suggestion, and nothing downstream can delete the duplicate.
      #
      # One retry, bounded like #produce_plan's options retry. Retrying is safe
      # here precisely because nothing has been created yet: the failure it covers
      # is a lost request, not a duplicate work package.
      def write_work_packages(st, request, project_name, types, related, retry_bad: true, format_note: nil)
        log_script "Writer: drafting work packages from #{wp_label(st.item_id)} — #{request}"
        prompt = Prompts::WpWriter.create_wp(item_id: st.item_id, subject: st.subject,
                                   item: container_path(st.item_file), request: request,
                                   project: project_name, types: Helpers.types_for_prompt(types),
                                   max: MAX, related: related, format_note: format_note)
        reply = llm(:wp_writer, prompt, session_file: st.session_file).to_s
        # Only what follows the last `ANSWER:` marker; the writer's own deliberation
        # is scratch (Prompts::WpWriter.create_wp). Text with no marker is read whole, so an
        # answer that skips it still works.
        answer = Helpers.after_marker(reply, "ANSWER")

        if (questions = Helpers.needs_info(answer))
          log_script "create wp NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
          @reply.(st.item_id, "I need more information before I create a work package:\n\n#{questions}")
          return nil
        end

        drafts = Helpers.parse_work_packages(answer)
        # Over the cap is a SCOPE problem, not an unusable answer: the blocks read
        # fine, so a retry would produce the same list. Say the number and stop.
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
          # The retry names what was WRONG with the answer. The block format is
          # strict and the prompt is otherwise identical, so an unnamed miss would
          # be repeated word for word and both attempts spent on the same slip.
          return write_work_packages(st, request, project_name, types, related,
                                     retry_bad: false, format_note: Helpers.wp_format_miss(answer, many: true))
        end

        log_script "#{wp_label(st.item_id)} — the writer produced no usable work-package block twice."
        @reply.(st.item_id, "I could not draft the work package. Ask me again, and say in one " \
                            "sentence what it is about.")
        nil
      rescue Harness::Error => e
        # `error_length` means the model spent its whole output limit before writing
        # a draft — see server.js on a thinking block long enough to hit the cap.
        # Not retried: the same prompt would spend the same budget. Said plainly,
        # because the reader is waiting and "error_length" tells them nothing.
        raise unless e.message.to_s.include?("length")
        log_script "#{wp_label(st.item_id)} — the draft run hit the model's output limit (#{e.message})."
        @reply.(st.item_id,
          "I ran out of writing space before I finished the draft, so I created nothing. " \
          "Ask me again with a shorter, more specific request."
        )
        nil
      end

      # Preflight every payload, POST each one, record it, link it, report — in
      # that order, because each step must survive the next one failing.
      #
      # The whole set is preflighted BEFORE the first POST. That is the only
      # atomic-ish gate available (the form does not save), and half a tree is
      # worse than none when the halves cannot be deleted — the same rule `pd
      # generate-wp` follows before it writes a FEATURE.
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

        # Every record for this comment, not just this run's: an earlier partial
        # create leaves records behind, and the reader is owed the whole set.
        @reply.(st.item_id, created_note(ensure_links(st, intent.comment_at), failed))
      end

      # Every payload through the create form, stopping at the first one the
      # project rejects. `all?` short-circuits on purpose: one rejection means
      # nothing is created, so there is no reason to ask about the rest.
      def payloads_accepted?(st, payloads, types)
        many = payloads.length > 1
        payloads.all? { |_draft, payload| payload_accepted?(st, payload, types, many: many) }
      end

      # Ask OpenProject whether this payload would be accepted, before writing it.
      #
      # A project can REQUIRE custom fields — a required select, a required list —
      # and required-ness is per project AND type. Without this preflight the whole
      # command ends in a 422 in the log, after an LLM call has been spent, with the
      # reader told nothing.
      #
      # opilot must not fill such a field itself. A required custom field carries
      # business meaning that only a person has ("which release train?", "which
      # customer?"), a work package can never be deleted, and a guess would be
      # permanent. So the fields are named back to the reader, who can create it in
      # OpenProject or NAME A DIFFERENT TYPE — required-ness is per type, and their
      # answer lands in this thread, which the next draft reads (Prompts::WpWriter.create_wp's
      # TYPE line). Choosing another type here instead would be opilot re-classifying
      # somebody's work to get past a validation, on a work package nobody can delete.
      #
      # The form runs the same SetAttributesService the create runs and simply does
      # not save, so a payload it accepts is one the create accepts, and the defaults
      # it applies are applied by the create too — which is why the payload is sent
      # on unchanged rather than replaced by the form's version.
      def payload_accepted?(st, payload, types, many: false)
        form = @api.create_work_package_form(payload)
        # A form that answered 403, 404 or a proxy's HTML did not run, so let the
        # create speak for itself rather than block on a preflight that never happened.
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

      # Name what the project demands, in its own words. The API's messages are the
      # field labels a person sees in OpenProject ("Cécile Hierarchy … can't be
      # blank"), so they are quoted rather than paraphrased.
      #
      # `subject` names WHICH work package was rejected, and is passed only when
      # the request asked for several: the whole set is then abandoned over one
      # rejection, so the reader needs to know which one carried it.
      def required_fields_note(errors, types, subject: nil)
        reasons = errors.map { |field, error| "- #{error["message"]} (`#{field}`)" }.join("\n")
        opening = if subject
                    "I cannot create #{subject.inspect}, so I created none of them."
                  else
                    "I cannot create the work package."
                  end
        note = +"#{opening} This project needs values I must not invent:\n\n#{reasons}\n\n" \
                "Create the work package in OpenProject, and I can work on it there."
        # Required-ness is per type, so another type may need none of this — and
        # asking again with a type named is the one-comment way out.
        names = types.map { |t| t["name"] }.reject(&:empty?)
        if names.length > 1
          note << " You can also ask me again and name a different type — this project has: " \
                  "#{names.join(", ")}."
        end
        note
      end

      # The v3 create body. `_links.type` is present only when the draft named a
      # type this project has: with no type at all OpenProject assigns the project's
      # first enabled type, which is a fallback worth logging but not worth failing
      # over.
      def create_wp_payload(st, draft, project_id, types)
        Clients::OpenProject::Payload.work_package(
          project: project_id, type: chosen_type(st, draft, types),
          subject: draft["subject"], description: create_wp_description(st, draft)
        )
      end

      # The type to create under: the one the draft named, else the project's first.
      #
      # Named explicitly rather than left to the API, which would pick
      # `project.enabled_types.first` anyway — the same kind of choice, but invisible
      # in the payload, absent from the log, and (because a schema is per project AND
      # type) validated against a type nobody stated. `./opilot op wp create` requires
      # a type for the same reason.
      #
      # nil only when the type list could not be read at all; then the API's default
      # is better than no work package.
      def chosen_type(st, draft, types)
        named = Resource.find_named(types, draft["type"])
        return named if named

        fallback = types.first
        log_script "create wp for #{wp_label(st.item_id)} — type #{draft["type"].inspect} is not on this " \
                   "project; using #{fallback ? fallback["name"].inspect : "the API's default"}."
        fallback
      end

      # The new work package's description, opening with where it came from — the
      # same provenance line pd writes, and the reader's only backlink when the
      # relation is the part that failed.
      def create_wp_description(st, draft)
        origin = "Created by opilot from the discussion in " \
                 "[#{wp_label(st.item_id)}](#{Helpers.wp_url(@ctx, st.item_id)})."
        "#{origin}\n\n#{draft["description"]}".strip
      end

      # ── the created-work-package records ──────────────────────────────────────
      #
      # created_wps.json, keyed by the TRIGGER COMMENT's timestamp: an OpenProject::Intent
      # carries no comment id, and comment_at is the key OpenProject::Pull#mark_acted already
      # de-dupes on. One trigger can hold SEVERAL records, and each is written the
      # moment its POST returns 201 — before the link and before the reply — so a
      # crash after a create can never look like a create that never happened, and
      # a partial set can never be created twice.

      def created_wps(st)
        Helpers.safe_json_read(st.created_wps_file) || []
      end

      # Every work package this trigger comment created, in creation order.
      def records_for(records, comment_at)
        records.select { |r| r["comment_at"] == comment_at.to_s }
      end

      # `link_wanted` is the shape the block ASKED FOR (`Helpers::WP_LINKS`, mapped
      # to the API's own words), stored on the record rather than worked out later:
      # it is a per-work-package decision the writer states, so nothing downstream
      # may infer it from the size of the set. `asked_type` is the type the block
      # named, kept so the report can say when #chosen_type had to substitute
      # another.
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

      # Link every work package this comment created back to the one that asked for
      # it, skipping any already linked. Returns all of that comment's records —
      # [] when it created nothing — so the caller can both report them and finish
      # a link an earlier run failed to make.
      #
      # Best-effort, always: a link needs a permission the create does not
      # (:manage_work_package_relations for a relation, :manage_subtasks for a
      # parent), and the work package already exists and cannot be deleted. Losing
      # the run over a missing link would be the wrong trade.
      def ensure_links(st, comment_at)
        records = created_wps(st)
        mine    = records_for(records, comment_at)
        return [] if mine.empty?

        linked = mine.reject { |r| r["related"] }.count { |record| link_record(st, record) }
        Helpers.write_json_atomic(st.created_wps_file, records, "created_wps", pretty: true) if linked.positive?
        mine
      end

      # One link, in the shape the create asked for, falling back to a relation.
      # Returns whether the record changed.
      #
      # A legacy record has no `link_wanted` and reads as "relates", which is what
      # every record written before this existed actually got.
      #
      # The parent is set with its own PATCH and never in the create payload:
      # hierarchy needs :manage_subtasks, so in the payload a missing permission
      # would kill the create itself, while here it costs only the shape of the
      # link. `relates` is the fallback because a work package with no link at all
      # loses its provenance to the description alone.
      def link_record(st, record)
        wanted = record["link_wanted"] == "parent" ? "parent" : "relates"
        return true if record_linked!(record, wanted, set_link(record, wanted))
        return false unless wanted == "parent"

        log_script "#{wp_label(st.item_id)} — could not make #{wp_label(record["id"])} a child of it; " \
                   "relating it instead."
        record_linked!(record, "relates", set_link(record, "relates"))
      end

      # Mark the record linked when the call landed. Returns whether it did.
      def record_linked!(record, shape, code)
        return false unless [200, 201].include?(code)
        record["related"] = true
        record["link"]    = shape
        true
      end

      # Make one link and return the HTTP code, or nil when the call raised. Both
      # ids are numeric, which is why the record keeps them.
      #
      # For a relation the new work package is the `from` (the route work package
      # becomes `from`), so it reads "the new one relates to the source".
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

      # A markdown link to a created work package. Never a bare "#123": these are
      # read in OpenProject, where the id alone is not a link.
      def created_wp_link(record)
        subject = record["subject"].to_s.strip
        label   = subject.empty? ? wp_label(record["id"]) : "#{wp_label(record["id"])} #{subject}"
        "[#{label}](#{record["url"]})"
      end

      # ── what the reader is told ───────────────────────────────────────────────
      #
      # Composed in Ruby, not by the writer, for #post_options' reason: the wording
      # states what actually happened — which links exist, which are children,
      # which failed — and a sentence the LLM writes can drift from that.

      # The one comment a create is reported with. `failed` are the drafts whose
      # POST did not land; a re-fired trigger creates nothing more, so the reader
      # is told to ask again for those alone.
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

      # The re-fire answer: the same set, named again.
      def already_created_note(records)
        if records.length == 1
          return "I already created #{created_wp_link(records.first)} for that request." \
                 "#{single_notes(records.first)}"
        end

        "I already created these for that request:\n\n#{records.map { |r| created_line(r) }.join("\n")}"
      end

      # One work package's shape and exceptions, as sentences — the single case is
      # the common one and reads better as prose than as a parenthesis.
      #
      # The shape is always STATED, never implied: whether an offshoot is a child of
      # this work package or a peer beside it is the writer's per-block decision
      # (Prompts::WpWriter.create_wp's LINK line), so the reader cannot work it out from the
      # count and must be told.
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

      # What this line's link is, in the reader's terms. Every line carries it, so a
      # mixed set (some children, some peers) reads correctly.
      #
      # `related` is read FIRST, exactly as #single_notes reads it: it is the field
      # that says whether ANY link landed, and a record written before `link`
      # existed has only that one. Checking `link` first would report such a record
      # as unlinked.
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

      # [asked, got] when the create used a different type from the one the block
      # named (#chosen_type substitutes the project's first), else nil. The create
      # response titles the type it linked, so this is what the instance really
      # stored rather than what the payload hoped for.
      def substituted_type(record)
        asked = record["asked_type"].to_s.strip
        got   = record["type"].to_s.strip
        return nil if asked.empty? || got.empty? || asked.casecmp?(got)
        [asked, got]
      end
    end
  end
end
