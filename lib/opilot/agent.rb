require "json"
require "time"
require_relative "clients"

module OPilot
  # An inbound instruction parsed from an @opilot comment (see Pull#poll_intents).
  # `user` / `user_href` identify the commenter, so replies can address them.
  # `internal` is the trigger comment's visibility, so the reply can mirror it
  # (an internal @opilot prompt gets an internal answer, a public one a public).
  Intent = Struct.new(:item_id, :subject, :type, :command, :text, :comment_at,
                      :user, :user_href, :internal, keyword_init: true)

  POLL_INTERVAL = 20

  # The whole program: poll OpenProject for @opilot comments, turn each into an
  # Intent, and dispatch it through #handle. Per-WP "state" is just the files in
  # work_packages/<host>/<id>/ — plan.md present = has a plan; shipped means
  # every target repo has a repos/<name>/pr_url.txt (see Agent#shipped?).
  class Agent
    include Helpers

    def initialize(ctx, pull: Pull.new(ctx), harness: Harness.new(ctx), publish: Publish.new(ctx))
      @ctx     = ctx
      @pull    = pull
      @harness  = harness
      @publish = publish
      @api     = Clients::OpenProject.new(ctx.op_url, ctx.token)
    end

    def run
      ensure_harness!
      scan_from_at = setup
      puts "  Agent started — polling every #{POLL_INTERVAL}s. Ctrl-C to stop."

      loop do
        guarded_tick("OpenProject poll") { tick(scan_from_at) }
        sleep POLL_INTERVAL
      end
    end

    # Resolve the scan window, verify opilot's own OpenProject identity is
    # resolvable (fails loudly here, before the loop starts — see
    # Pull#ensure_bot_identity!), and print the allowlist banner. The returned
    # scan window is passed to #tick. Split out from #run so CombinedAgent can
    # drive the loop.
    def setup
      scan_from_at = @pull.load_or_prompt_scan_from
      @pull.ensure_bot_identity!
      report_op_mcp_status
      if @ctx.allowed_op_user_ids.any?
        puts "  Allowlist active — only triggers from user ids: #{@ctx.allowed_op_user_ids.join(", ")}"
      else
        # `create wp` is named only here, in the state where it is switched off:
        # "created nothing" and "cannot create anything" look identical in a log,
        # while a line confirming the normal state is noise on every start.
        puts "  No allowlist set (OPILOT_ALLOWED_OP_USER_IDS) — any user can trigger @opilot, " \
             "and `create wp` is off."
      end
      scan_from_at
    end

    # One poll-and-handle pass over OpenProject @opilot triggers (no sleep).
    def tick(scan_from_at)
      intents = @pull.poll_intents(scan_from_at)
      n = intents.length
      log_script "Polled OpenProject (#{@ctx.op_url}) — #{@pull.scanned_count} work package(s), " \
                 "#{@pull.changed_count} changed, #{n} @opilot trigger#{n == 1 ? "" : "s"}"
      intents.each { |intent| handle_and_ack(intent) }
    end

    # Handle one intent, then mark its trigger acted. A *handled* error (raised
    # and caught here) is logged and still acked, so a permanent failure — e.g. a
    # denied push — is not replayed every poll. We do NOT post an error note to
    # the WP: a transient failure (e.g. an LLM error_during_execution) would
    # leave noise on the work package for no benefit. Only a hard crash or a
    # Ctrl-C (SystemExit is not a StandardError, so it passes this rescue)
    # leaves the trigger for the next poll to retry.
    def handle_and_ack(intent)
      handle(intent)   # sets @requester as its first step
      ack(intent)
    rescue => e
      log_script "Error on #{wp_label(intent.item_id)} (#{intent.command}): #{e.class}: #{e.message}"
      ack(intent)
    end

    # Mark the trigger comment acted, so it is not re-emitted on the next poll.
    def ack(intent)
      @pull.mark_acted(intent.item_id, intent.comment_at)
    end

    def handle(intent)
      log_script "#{wp_label(intent.item_id)} — #{intent.command} — #{intent.subject}"
      @requester = requester_mention(intent)   # who to address in replies
      @reply_internal = intent.internal        # mirror the trigger's visibility
      case intent.command
      when :chat      then handle_chat(intent)
      when :ship      then handle_ship(intent)
      when :create_wp then handle_create_wp(intent)
      end
    end

    private

    # An OpenProject mention of the commenter, so replies notify and address them
    # by name.
    def requester_mention(intent)
      Helpers.mention(intent.user, intent.user_href)
    end

    # Prefix a reply with the requester mention, when known.
    def addressed(msg)
      @requester.to_s.empty? ? msg : "#{@requester} #{msg}"
    end

    # ── command handlers ──────────────────────────────────────────────────────

    def handle_chat(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      # Answer against current upstream. Scoped to the WP's target repos when the
      # plan has already named them — a chat almost always follows a plan, and
      # syncing the whole registry to answer one question is wasted fetching.
      sync_bases_for_reading(st.repos)
      # Pass the plan's path, not its text: a resumed session already holds the
      # plan, so re-embedding it every turn just burns tokens.
      plan_ref = st.plan_file.exist? ? container_path(st.plan_file) : "(no plan yet)"
      prompt = Prompts.chat(item_id: st.item_id, subject: st.subject,
                            item: container_path(st.item_file),
                            plan: plan_ref, message: intent.text.to_s,
                            related: related_ref(st), can_create_wp: create_wp_enabled?,
                            op_mcp: @ctx.op_mcp?)
      reply = @harness.run(prompt, tools: read_tools, session_file: st.session_file)
      post_note(st.item_id, addressed(reply.strip)) unless reply.strip.empty?
    end

    # ── create wp ─────────────────────────────────────────────────────────────

    # `@opilot create wp <what>` — split something out of this thread into its own
    # work package.
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
    def handle_create_wp(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      return note_create_wp_disabled(st) unless create_wp_enabled?

      # Created from this very comment already? Re-report them, and finish any
      # link that was the part that failed. This is what stops a re-fired
      # trigger — a crash before the ack, the same comment posted twice — from
      # minting a second set of work packages for one request. It reports every
      # record for the comment, including after a PARTIAL create: the ones that
      # landed are the answer, and asking again creates nothing more.
      records = ensure_links(st, intent.comment_at)
      if records.any?
        post_note(st.item_id, addressed(already_created_note(records)))
        return
      end

      request = intent.text.to_s.strip
      if request.empty?
        post_note(st.item_id, addressed(
          "Tell me what to create. Write `create wp` and then what the new work package " \
          "is about — the person or the suggestion in this thread."
        ))
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
      post_note(intent.item_id,
                addressed("I could not create the work package. The reason is in my log: #{e.message}"))
    end

    # Whether `create wp` runs at all. It needs a non-empty allowlist, and that is
    # not a style choice: a work package can never be deleted, and with no
    # allowlist every user who can comment could mint them without limit.
    #
    # It also makes the allowlist gate unconditional for this command —
    # Pull#intent_from_comments drops a non-allowlisted trigger whenever a list
    # exists, so every create request that reaches here is from a listed user.
    def create_wp_enabled?
      @ctx.allowed_op_user_ids.any?
    end

    # How many work packages one request may create. Stated in the prompt and
    # enforced HERE, because a prompt limit drifts and a work package can never
    # be deleted: "create one for every suggestion in this thread" must not be
    # able to mint twenty rows nobody can remove. Five also sits well inside one
    # output budget — see Prompts.create_wp on why a cut-off answer is the
    # failure mode to fear.
    MAX_CREATE_WP = 5

    # Say once per work package that the command is switched off. Once, not once
    # per comment, for Pull#note_refused_trigger's reason: a reply is the one
    # thing this path can be made to produce, and a per-comment answer would let
    # anyone fill the activity tab.
    def note_create_wp_disabled(st)
      data = Helpers.safe_json_read(st.item_file) || {}
      return if data["create_wp_refusal_noted_at"]

      code = post_note(st.item_id, addressed(
        "I do not create work packages on this instance. The administrator must set " \
        "OPILOT_ALLOWED_OP_USER_IDS first, because a work package can never be deleted."
      ))
      return unless code == 201

      data["create_wp_refusal_noted_at"] = Time.now.utc.iso8601
      st.item_file.write(JSON.generate(data))
    end

    # The source work package, fetched FRESH: item.json caches no project, and the
    # cached id may be semantic ("PROJ-123") while the relation endpoint takes
    # only numeric ids. Returns nil (having answered) when it cannot be read.
    def fetch_source_wp(st)
      code, wp = @api.work_package(st.item_id)
      unless code == 200 && wp
        post_note(st.item_id, addressed("I could not read this work package from the API (HTTP #{code}), " \
                                        "so I created nothing."))
        return nil
      end
      project_id = wp.dig("_links", "project", "href").to_s.split("/").last
      if project_id.to_s.empty?
        post_note(st.item_id, addressed("I could not tell which project this work package belongs to, " \
                                        "so I created nothing."))
        return nil
      end
      { "numeric_id" => wp["id"].to_s, "project_id" => project_id }
    end

    # The project resource, and the permission check on it. A SECOND GET on
    # purpose: the work package carries only a link stub for its project, and the
    # createWorkPackage links this checks are rendered on the project itself.
    # Asked before the LLM call, so a token without :add_work_packages costs a
    # request rather than a whole draft.
    def fetch_project_for_create(st, project_id)
      code, project = @api.project(project_id)
      unless code == 200 && project
        post_note(st.item_id, addressed("I could not read project #{project_id} (HTTP #{code}), " \
                                        "so I created nothing."))
        return nil
      end
      unless Helpers.create_wp_allowed?(project)
        post_note(st.item_id, addressed(
          "I cannot create work packages in #{project["name"]}. My OpenProject token has no " \
          "`add_work_packages` permission there. Ask an administrator for it."
        ))
        return nil
      end
      project
    end

    # The types this project really offers, so the draft cannot name one that does
    # not exist. Best-effort: an empty list only means the runner lets OpenProject
    # pick the project's default type.
    def project_type_names(project_id)
      code, body = @api.project_types(project_id)
      return [] unless code == 200 && body
      Helpers.type_list(body)
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
      prompt = Prompts.create_wp(item_id: st.item_id, subject: st.subject,
                                 item: container_path(st.item_file), request: request,
                                 project: project_name, types: types_for_prompt(types),
                                 max: MAX_CREATE_WP, related: related, format_note: format_note)
      reply = @harness.run(prompt, tools: Harness::TOOLS_READ, session_file: st.session_file).to_s
      # Only what follows the last `ANSWER:` marker; the writer's own deliberation
      # is scratch (Prompts.create_wp). Text with no marker is read whole, so an
      # answer that skips it still works.
      answer = Helpers.after_marker(reply, "ANSWER")

      if answer.lstrip.start_with?("NEEDS_INFO")
        questions = answer.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip
        log_script "create wp NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
        post_note(st.item_id, addressed("I need more information before I create a work package:\n\n#{questions}"))
        return nil
      end

      drafts = Helpers.parse_work_packages(answer)
      # Over the cap is a SCOPE problem, not an unusable answer: the blocks read
      # fine, so a retry would produce the same list. Say the number and stop.
      if drafts.length > MAX_CREATE_WP
        log_script "#{wp_label(st.item_id)} — the writer produced #{drafts.length} work packages; " \
                   "the cap is #{MAX_CREATE_WP}, so nothing was created."
        post_note(st.item_id, addressed(
          "That request comes to #{drafts.length} work packages, and I create at most " \
          "#{MAX_CREATE_WP} at a time, because a work package can never be deleted. " \
          "I created nothing. Ask me again for a smaller set."
        ))
        return nil
      end
      return drafts if drafts.any?
      if retry_bad
        # The retry names what was WRONG with the answer. The block format is
        # strict and the prompt is otherwise identical, so an unnamed miss would
        # be repeated word for word and both attempts spent on the same slip.
        return write_work_packages(st, request, project_name, types, related,
                                   retry_bad: false, format_note: format_miss(answer))
      end

      log_script "#{wp_label(st.item_id)} — the writer produced no usable work-package block twice."
      post_note(st.item_id, addressed("I could not draft the work package. Ask me again, and say in one " \
                                      "sentence what it is about."))
      nil
    rescue Harness::Error => e
      # `error_length` means the model spent its whole output limit before writing
      # a draft — see server.js on a thinking block long enough to hit the cap.
      # Not retried: the same prompt would spend the same budget. Said plainly,
      # because the reader is waiting and "error_length" tells them nothing.
      raise unless e.message.to_s.include?("length")
      log_script "#{wp_label(st.item_id)} — the draft run hit the model's output limit (#{e.message})."
      post_note(st.item_id, addressed(
        "I ran out of writing space before I finished the draft, so I created nothing. " \
        "Ask me again with a shorter, more specific request."
      ))
      nil
    end

    # Which part of the block format the last answer missed, said back to the
    # writer on the one retry. Read off the answer itself rather than from the
    # parser, because the parser's answer is only "nothing usable" — and the
    # three misses below need three different corrections.
    def format_miss(answer)
      # WP_BEGIN/WP_END anchor a whole LINE, so they are matched line by line.
      lines = answer.to_s.lines.map(&:chomp)
      if lines.none? { |l| l.match?(Helpers::WP_BEGIN) }
        "Your last answer had no `BEGIN WORK PACKAGE` line. Every work package needs " \
          "one, alone on its own line, and a closing `END WORK PACKAGE` line."
      elsif lines.none? { |l| l.match?(Helpers::WP_END) }
        "Your last answer opened a block and never closed it. Write the closing " \
          "`END WORK PACKAGE` line for every block, alone on its own line."
      else
        "Your last answer's blocks were unreadable — the first line inside each one " \
          "must be `SUBJECT: <one line>`."
      end
    end

    # The TYPE line's menu. An empty registry is stated rather than left blank, so
    # the writer omits the line instead of inventing a type name.
    def types_for_prompt(types)
      names = types.map { |t| t["name"] }.reject(&:empty?)
      names.empty? ? "(unknown — leave the TYPE line out)" : names.join(", ")
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
        code, body = @api.create_work_package(payload)
        last_code = code
        unless code == 201 && body
          log_script "create wp failed for #{wp_label(st.item_id)} — HTTP #{code} on #{payload["subject"].inspect}"
          failed << draft
          next
        end
        record = record_created_wp(st, intent, wp, body, draft: draft)
        created << record
        log_script "Created #{wp_label(record["id"])} from #{wp_label(st.item_id)}"
        record_progress(st.item_id, "-", "created-wp:#{record["id"]}")
      end

      if created.empty?
        subject = failed.length == 1 ? "the work package" : "any of the #{failed.length} work packages"
        post_note(st.item_id, addressed("I could not create #{subject} (HTTP #{last_code}). " \
                                        "The response is in my log."))
        return
      end

      # Every record for this comment, not just this run's: an earlier partial
      # create leaves records behind, and the reader is owed the whole set.
      post_note(st.item_id, addressed(created_note(ensure_links(st, intent.comment_at), failed)))
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
    # answer lands in this thread, which the next draft reads (Prompts.create_wp's
    # TYPE line). Choosing another type here instead would be opilot re-classifying
    # somebody's work to get past a validation, on a work package nobody can delete.
    #
    # The form runs the same SetAttributesService the create runs and simply does
    # not save, so a payload it accepts is one the create accepts, and the defaults
    # it applies are applied by the create too — which is why the payload is sent
    # on unchanged rather than replaced by the form's version.
    def payload_accepted?(st, payload, types, many: false)
      code, form = @api.create_work_package_form(payload)
      # Not an answer about the payload (403, 404, an HTML error from a proxy):
      # let the create speak for itself rather than blocking on a preflight that
      # did not run.
      unless code == 200 && form.is_a?(Hash)
        log_script "#{wp_label(st.item_id)} — the create form answered HTTP #{code}; creating without it."
        return true
      end

      errors = form.dig("_embedded", "validationErrors")
      return true if !errors.is_a?(Hash) || errors.empty?

      log_script "#{wp_label(st.item_id)} — the project rejects #{payload["subject"].inspect}: " \
                 "#{errors.keys.join(", ")}"
      post_note(st.item_id, addressed(required_fields_note(errors, types,
                                                           subject: many ? payload["subject"] : nil)))
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
      links = { "project" => { "href" => "/api/v3/projects/#{project_id}" } }
      type  = chosen_type(st, draft, types)
      links["type"] = { "href" => "/api/v3/types/#{type["id"]}" } if type

      { "subject"     => draft["subject"][0, 200],
        "description" => { "format" => "markdown", "raw" => create_wp_description(st, draft) },
        "_links"      => links }
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
      named = Helpers.find_type(types, draft["type"])
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
    # created_wps.json, keyed by the TRIGGER COMMENT's timestamp: an Intent
    # carries no comment id, and comment_at is the key Pull#mark_acted already
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
                 "id"                => Helpers.display_id(body),
                 "numeric_id"        => body["id"].to_s,
                 "source_numeric_id" => wp["numeric_id"],
                 "subject"           => body["subject"].to_s,
                 "url"               => Helpers.wp_url(@ctx, Helpers.display_id(body)),
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
      code, = if shape == "parent"
                @api.update_work_package(
                  record["numeric_id"],
                  { "_links" => { "parent" => { "href" => "/api/v3/work_packages/#{source}" } } }
                )
              else
                @api.create_relation(record["numeric_id"], source)
              end
      log_script "#{wp_label(record["id"])} — #{shape} link to #{wp_label(source)} answered HTTP #{code}." \
        unless [200, 201].include?(code)
      code
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
    # (Prompts.create_wp's LINK line), so the reader cannot work it out from the
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

    # The fix intent: plan, implement, and open the prototype.
    #
    # This is where every `build` trigger lands (alias `fix`). There is
    # no separate plan-and-wait command any more: a fix with more than one defensible
    # shape stops and offers numbered options (Prompts::OPTIONS_CONTRACT), and a
    # fix with one shape is announced (#post_approach_note) and shipped in the
    # same call — so a simple ticket still costs exactly one plan call, just
    # with a stated approach instead of a silent one. NEEDS_INFO still guards
    # blind fixes. Once a prototype exists the work moves to the pull request
    # and this handler only points there (#report_shipped).
    def handle_ship(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      # The approach the reader settled: a chosen option (with anything they wrote
      # after the number folded in) or their free text.
      direction = (option_focus(st, intent.text) || intent.text.to_s).strip

      # 1. A prototype already exists, so this work package's part is done: point
      #    at the pull request, and spend no plan call doing it.
      if shipped?(st)
        report_shipped(st, direction: direction)
        return
      end

      # 2. A plan is on file and nobody gave new direction: build it as it reads.
      #    This is the only way to get a prototype of the exact plan a human has
      #    already read.
      return ship(st) if Helpers.file_has_content?(st.plan_file) && direction.empty?

      # 3. An offer is standing and the reply names no option: post the same list
      #    again (no LLM call), because the question is still the question.
      if direction.empty? && Helpers.file_has_content?(st.options_file)
        post_options(st)
        return
      end

      # 4. Nothing has settled the approach: this is the one call that may ask.
      case produce_plan(st, direction, allow_options: direction.empty?)
      when :options then post_options(st)
      when :ok      then ship(st)
      end
    end

    # ── shared steps ──────────────────────────────────────────────────────────

    # Generate (or revise) the plan for a WP. Returns :ok when plan.md is saved
    # (having already posted an approach note when the writer named a single
    # option — see below), :needs_info (having already posted the questions as
    # a note), or :options when the writer stopped after naming more than one
    # approach (options.json written, the comment left to the caller).
    #
    # `allow_options:` is the caller's judgment that no human has picked an
    # approach yet; the writer's judgment is whether the fix really has more than
    # one shape (Prompts::OPTIONS_CONTRACT). `:failed` means the call produced
    # neither a plan nor a usable options answer, and is handled like any other
    # failed run — logged, never commented.
    def produce_plan(st, feedback, allow_options: false, retry_bad_options: true)
      # Planning is read-only across every repo's worktree (all mounted at
      # /repos/<name>); the branch checkout waits until #ship, once the LLM has
      # chosen the target repo(s) in the plan.
      #
      # Every repo is synced, not just the eventual targets: which repos the fix
      # lands in is the plan's own output, so at this point there is nothing
      # narrower to sync, and the LLM reads across the registry to decide.
      sync_bases_for_reading(@ctx.repos.all)
      item_c  = container_path(st.item_file)
      plan_c  = container_path(st.plan_file)
      related = related_ref(st)
      menu    = repos_for_prompt(@ctx.repos.all)

      if feedback && !feedback.empty? && st.plan_file.exist?
        log_script "Writer: revising plan for #{wp_label(st.item_id)} from feedback"
        prompt = Prompts.replan(repos_summary: @ctx.repos.summary, repos: menu, item: item_c, plan: plan_c,
                                feedback: feedback, item_id: st.item_id, title: st.subject,
                                resumed: session_resumable?(st), related: related, op_mcp: @ctx.op_mcp?)
        @harness.capture(prompt, tools: read_tools, outfile: st.plan_file,
                        session_file: st.session_file)
        record_chosen_repos(st)
        return :ok
      end

      log_script "Writer: generating plan for #{wp_label(st.item_id)} — #{st.subject}"
      prompt = Prompts.plan(repos_summary: @ctx.repos.summary, repos: menu, item: item_c,
                            item_id: st.item_id, title: st.subject, hint: feedback.to_s,
                            related: related, allow_options: allow_options, op_mcp: @ctx.op_mcp?)
      @harness.capture(prompt, tools: read_tools, outfile: st.plan_file,
                      session_file: st.session_file)

      if st.plan_file.read.lstrip.start_with?("NEEDS_INFO")
        questions = st.plan_file.read.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip
        safe_rm(st.plan_file)
        log_script "Plan NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
        post_note(st.item_id, addressed("I need more information before I can plan this change:\n\n#{questions}"))
        return :needs_info
      end

      # The sentinel is read whether or not options were invited, so an
      # uninvited OPTIONS block can never be committed and shipped as a plan.
      if st.plan_file.read.lstrip.start_with?(Prompts::OPTIONS_SENTINEL)
        options, remainder = Helpers.parse_leading_options(st.plan_file.read)

        # The common case: one named approach, straight into its plan in the
        # same response. Ship it — no waiting, no extra call — after saying
        # what's about to be built.
        if allow_options && options.length == 1 && !remainder.strip.empty?
          st.plan_file.write(remainder)
          record_chosen_repos(st)
          post_approach_note(st, options.first)
          return :ok
        end

        safe_rm(st.plan_file)                    # the file holds no usable plan
        if allow_options && options.length > 1
          st.options_file.write("#{JSON.pretty_generate(options)}\n")
          log_script "Options offered for #{wp_label(st.item_id)} — #{options.length}"
          return :options
        end
        unless retry_bad_options
          log_script "#{wp_label(st.item_id)} — the writer answered with options twice; no plan produced."
          return :failed
        end
        # An unusable list, a named approach with no plan attached, or options
        # nobody asked for: ask once more for a plan. Bounded to one retry, so
        # a writer that keeps failing to follow the contract ends the trigger
        # instead of looping.
        log_script "Unusable OPTIONS for #{wp_label(st.item_id)} — asking for one plan instead."
        return produce_plan(st, feedback, allow_options: allow_options, retry_bad_options: false)
      end

      record_chosen_repos(st)
      :ok
    end

    # The single-shape case: no choice to offer, so say what's about to be
    # built instead of silently going straight to implementation.
    def post_approach_note(st, option)
      post_note(st.item_id, addressed(
        "This is a straightforward problem, so I will now implement the following " \
        "approach: #{option["title"]} — #{option["summary"]}"
      ))
    end

    # ── implementation options ────────────────────────────────────────────────

    # The plan-prompt focus for an option the reporter selected, or nil when the
    # comment names no saved option (it is then plain direction).
    def option_focus(st, text)
      Helpers.option_choice(Helpers.safe_json_read(st.options_file) || [], text)
    end

    # Post the offered options as one work-package comment.
    #
    # Composed here rather than by the LLM so the wording, the numbering and the
    # reply instructions are the same every time, and so no heading or sign-off
    # can reach the activity tab; the writer supplies only the title and the
    # sentence.
    def post_options(st)
      options = Helpers.safe_json_read(st.options_file) || []
      return if options.empty?

      entries = options.map do |o|
        # An estimate, not a promise: the plan's own REPOS line decides where the
        # fix lands, and the size is the writer's guess before it writes any code.
        tag = [o["repos"].to_a.join(", "), o["size"]].reject { |s| s.to_s.strip.empty? }.join(" · ")
        entry = "**#{o["n"]} — #{o["title"]}** — #{o["summary"]}"
        tag.empty? ? entry : "#{entry}\nestimate: #{tag}"
      end
      first = options.first["n"]
      body = +"I can fix this in #{options.length} ways. Pick one, or describe a different way.\n\n"
      body << entries.join("\n\n")
      body << "\n\nReply `@opilot build #{first}` to build option #{first}. " \
              "Add words after the number to change that option. " \
              "Reply `@opilot build` with your own approach if no option fits."
      body << "\n\nOnly a user on opilot's allowlist can select an option." if @ctx.allowed_op_user_ids.any?

      post_note(st.item_id, addressed(body))
    end

    # ── an existing prototype ─────────────────────────────────────────────────

    # Every target repo already has a published PR.
    def shipped?(st)
      st.repos.any? && st.repos.all? { |r| Helpers.file_has_content?(st.pr_url_file(r)) }
    end

    def pr_links(st)
      st.repos.map { |r| st.pr_url_file(r).read.strip }.join("\n")
    end

    # The work package's part is over once a prototype exists: the review of the
    # code happens on the pull request, where opilot reads comments and pushes
    # changes (gh-agent). Two tracks for one fix would split the record of it, so
    # a request made here is answered with the link rather than acted on.
    #
    # Planning again would also be wrong on its own: it rewrites plan.md while the
    # PR keeps linking the gist of the plan as it was, so the two would silently
    # disagree.
    def report_shipped(st, direction: "")
      lead = if direction.to_s.strip.empty?
               "this work package is already shipped:"
             else
               "I do not change the code from here. Ask for the change on the pull request, " \
               "where I read the comments and push the changes:"
             end
      post_note(st.item_id, addressed("#{lead}\n\n#{pr_links(st)}"))
    end

    # Turn the saved plan into a draft PR. Idempotent/resumable: re-reports an
    # existing PR, and skips implementation when the branch already has commits.
    def ship(st)
      # Already shipped to every target repo? Re-report the existing PR links.
      # #handle_ship catches this first; the guard stays for every other caller.
      if shipped?(st)
        report_shipped(st)
        return
      end

      changed = implement_plan(st)
      if changed.empty?
        log_script "#{wp_label(st.item_id)} — no changes produced, nothing to ship."
        post_note(st.item_id, addressed("I made no changes. The plan possibly changes nothing, or it is already applied."))
        return
      end

      opened = []
      failed = []
      changed.each do |repo|
        generate_pr_description(st, repo)
        url = @publish.open_pr(st.item_id, st.subject, st.branch, repo)
        if url
          record_progress(st.item_id, st.branch, "shipped:#{repo.name}")
          opened << [repo, url]
        else
          failed << repo
        end
      end

      if opened.any?
        links = opened.map { |repo, url| "- [#{st.subject}](#{url}) — `#{repo.name}`" }.join("\n")
        suffix = failed.any? ? "\n\n(I could not open a PR in: #{failed.map(&:name).join(", ")}. Make sure GITHUB_CONTRIBUTOR_TOKEN is set.)" : ""
        post_note(st.item_id, addressed("Here is your AI-generated prototype#{opened.size > 1 ? "s" : ""}:\n\n#{links}#{suffix}"))
      else
        post_note(st.item_id, addressed("I implemented the change and committed it on `#{st.branch}`. I could not open the PR. Make sure GITHUB_CONTRIBUTOR_TOKEN is set."))
      end
    end

    # ── notifications ─────────────────────────────────────────────────────────

    # Replies mirror the trigger comment's visibility: an internal @opilot prompt
    # gets an internal answer, a public one a public answer. Defaults to internal
    # (the safer side) when visibility is unknown — e.g. an error before #handle
    # set @reply_internal.
    def post_note(item_id, raw)
      internal = @reply_internal.nil? ? true : @reply_internal
      # The reply's id is not recorded anywhere: Pull#own_comment? recognises
      # opilot's own comments by their author, so there is nothing to bookkeep.
      code, = @api.add_comment(item_id, comment: raw, internal: internal)
      if code == 201
        log_script "Note posted to WP #{wp_label(item_id)}"
      else
        log_script "Note failed for WP #{wp_label(item_id)} (HTTP #{code})"
      end
      code
    end
  end
end
