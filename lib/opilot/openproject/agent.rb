require "json"
require "time"
require "digest"

module OPilot
  module OpenProject
    # The whole program: poll OpenProject for @opilot comments, turn each into an
    # OpenProject::Intent, and dispatch it through #handle. Per-WP "state" is just the files in
    # work_packages/<host>/<id>/ — plan.md present = has a plan; shipped means
    # every target repo has a repos/<name>/pr_url.txt (see OpenProject::Agent#shipped?).
    class Agent
      include Helpers

      attr_reader :pull

      def initialize(ctx, pull: OpenProject::Pull.new(ctx), harness: Harness.new(ctx), publish: GitHub::Publish.new(ctx))
        @ctx     = ctx
        @pull    = pull
        @harness  = harness
        @publish = publish
        @api     = Clients::OpenProject::Client.new(ctx.op_url, ctx.token)
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
      # OpenProject::Pull#ensure_bot_identity!), and print the allowlist banner. The returned
      # scan window is passed to #tick. Split out from #run so CombinedAgent can
      # drive the loop.
      def setup
        scan_from_at = @pull.load_or_prompt_scan_from
        @pull.ensure_bot_identity!
        report_mcp_status
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
        when :health    then handle_health(intent)
        end
      end

      # Run a command for another interface (Matrix::Agent): the same handler, with
      # every note sent to `reply` instead of the work package. `build_ref` goes
      # between `build` and the option number, so the offer names the id.
      def handle_elsewhere(intent, reply:, build_ref: nil)
        @reply_sink = reply
        @build_ref  = build_ref
        handle(intent)
      ensure
        @reply_sink = @build_ref = nil
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
        args = { item_id: st.item_id, subject: st.subject, item: container_path(st.item_file),
                 plan: plan_ref, related: related_ref(st, mirror: !op_mcp_live?), can_create_wp: CreateWp.enabled?(@ctx),
                 can_make_artifact: artifacts_enabled?, max_artifacts: MAX_ARTIFACTS, op_mcp: op_mcp_live? }
        prompt, rules = chat_prompt(st, args, intent.text.to_s)
        reply = llm(:advisor, prompt, session_file: st.session_file)
        mark_chat_rules(st, rules)
        # Only when artifacts are on: with the instructions never given, a BEGIN
        # ARTIFACT line is text the writer invented or quoted, and stripping it
        # would delete content from someone's reply.
        reply = publish_artifacts(st, intent, reply) if artifacts_enabled?
        post_note(st.item_id, addressed(reply.strip)) unless reply.strip.empty?
      end

      # The chat prompt and a digest of its rules (the full prompt without the
      # question). The full prompt goes once per session: a later turn gets the
      # short follow-up, but only when this session's last chat turn had the same
      # rules. A session the planner opened holds none of them, and a changed
      # flag or a new plan changes the rules.
      def chat_prompt(st, args, message)
        rules = Digest::SHA256.hexdigest(Prompts::Advisor.chat(**args, message: ""))
        if session_resumable?(st) && chat_rules_file(st).exist? &&
           chat_rules_file(st).read == "#{st.session_file.read.strip} #{rules}"
          [Prompts::Advisor.chat_follow_up(item: args[:item], message: message), rules]
        else
          [Prompts::Advisor.chat(**args, message: message), rules]
        end
      end

      def mark_chat_rules(st, rules)
        return unless session_resumable?(st)
        chat_rules_file(st).write("#{st.session_file.read.strip} #{rules}")
      end

      def chat_rules_file(st) = st.item_dir / "chat_rules"

      # Answers its own failure, like create wp: the reader waits for a report.
      def handle_health(intent)
        check = OpenProject::HealthCheck.new(@ctx, pull: @pull, harness: @harness, api: @api)
        report = begin
          check.run(intent.item_id, focus: intent.text.to_s, internal: intent.internal != false) ||
            "The health check could not read this work package."
        rescue Harness::Error => e
          log_script "Health check failed on #{wp_label(intent.item_id)}: #{e.message}"
          "The health check did not finish: the model run failed. Ask again with `@opilot health`."
        end
        post_note(intent.item_id, addressed(report))
      end

      # Take the artifacts out of a chat answer, mirror them, publish them as one
      # gist, and return the comment to post — the answer without the blocks, plus a
      # line naming what was published.
      def publish_artifacts(st, intent, reply)
        artifacts, text = Helpers.parse_artifacts(reply)
        return reply if artifacts.empty?

        kept, dropped = within_caps(artifacts)
        dir   = st.artifact_dir(intent.comment_at)
        files = {}
        kept.each do |artifact|
          name = Helpers.artifact_filename(artifact["filename"], taken: files.keys)
          (dir / name).write(artifact["content"])
          files[name] = artifact["content"]
        end
        log_script "#{Helpers.wp_label(st.item_id)}: #{files.size} artifact(s) → #{dir}"

        url = @publish.artifact_gist(st.item_id, st.subject, files)
        "#{text.strip}\n\n#{artifact_note(url, kept, dropped)}".strip
      end

      # Keep artifacts in order while both caps still hold; the rest are dropped.
      def within_caps(artifacts)
        total = 0
        kept  = artifacts.take_while do |artifact|
          total += artifact["content"].bytesize
          total <= MAX_ARTIFACT_BYTES
        end.first(MAX_ARTIFACTS)
        [kept, artifacts.size - kept.size]
      end

      # The line the comment ends with. Composed in Ruby, for #post_options' reason:
      # it states what actually happened, and a sentence the writer composed could
      # drift from it.
      def artifact_note(url, kept, dropped)
        lines = []
        if url.nil?
          lines << "I could not publish the artifact. Its content is not in this comment."
        elsif kept.size == 1
          lines << "📎 [#{artifact_title(kept.first)}](#{url})"
        else
          lines << "📎 I published #{kept.size} artifacts here: #{url}"
          lines.concat(kept.map { |a| "- #{artifact_title(a)}" })
        end
        # State the rule, not the cap that happened to bind: two caps drop
        # artifacts, and a sentence naming one of them would be false half the time.
        if dropped.positive?
          lines << "I did not publish #{dropped} more artifact(s). One answer may hold " \
                   "#{MAX_ARTIFACTS} at most, and #{MAX_ARTIFACT_BYTES / 1000} KB in total."
        end
        lines.join("\n")
      end

      def artifact_title(artifact)
        title = artifact["title"].to_s.strip
        title.empty? ? artifact["filename"].to_s : title
      end

      # `@opilot create wp` — see CreateWp.
      def handle_create_wp(intent)
        CreateWp.new(@ctx, api: @api, harness: @harness, pull: @pull,
                     reply: ->(item_id, msg) { post_note(item_id, addressed(msg)) }).run(intent)
      end

      # Whether a chat answer may publish artifacts: a publishing identity has to
      # exist, and the allowlist has to be set.
      #
      # The allowlist requirement is about EXFILTRATION, not permanence (a gist can
      # be deleted, unlike a work package). A gist is readable by anyone holding the
      # link, so without an allowlist any user who can comment could make opilot
      # lift an internal work package's text onto gist.github.com.
      def artifacts_enabled?
        !@publish.author_token.nil? && @ctx.allowed_op_user_ids.any?
      end

      # How many artifacts one answer may publish, and how many bytes they may total.
      # Stated in the prompt and enforced HERE, because a prompt limit drifts.
      MAX_ARTIFACTS      = 3
      MAX_ARTIFACT_BYTES = 60_000

      # The fix intent: plan, implement, and open the prototype.
      #
      # This is where every `build` trigger lands (alias `fix`). There is
      # no separate plan-and-wait command any more: a fix with more than one defensible
      # shape stops and offers numbered options (Prompts::Planner::OPTIONS_CONTRACT), and a
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
      # one shape (Prompts::Planner::OPTIONS_CONTRACT). `:failed` means the call produced
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
        related = related_ref(st, mirror: !op_mcp_live?)
        menu    = repos_for_prompt(@ctx.repos.all)

        if feedback && !feedback.empty? && st.plan_file.exist?
          log_script "Writer: revising plan for #{wp_label(st.item_id)} from feedback"
          prompt = Prompts::Planner.replan(repos_summary: @ctx.repos.summary, repos: menu, item: item_c, plan: plan_c,
                                  feedback: feedback, item_id: st.item_id, title: st.subject,
                                  resumed: session_resumable?(st), related: related, op_mcp: op_mcp_live?)
          llm(:planner, prompt, outfile: st.plan_file, session_file: st.session_file)
          record_chosen_repos(st)
          return :ok
        end

        log_script "Writer: generating plan for #{wp_label(st.item_id)} — #{st.subject}"
        prompt = Prompts::Planner.plan(repos_summary: @ctx.repos.summary, repos: menu, item: item_c,
                              item_id: st.item_id, title: st.subject, hint: feedback.to_s,
                              related: related, allow_options: allow_options, op_mcp: op_mcp_live?)
        llm(:planner, prompt, outfile: st.plan_file, session_file: st.session_file)

        if (questions = Helpers.needs_info(st.plan_file.read))
          safe_rm(st.plan_file)
          log_script "Plan NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
          post_note(st.item_id, addressed("I need more information before I can plan this change:\n\n#{questions}"))
          return :needs_info
        end

        # The sentinel is read whether or not options were invited, so an
        # uninvited OPTIONS block can never be committed and shipped as a plan.
        if Helpers.options_sentinel?(st.plan_file.read)
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
        build = ["@opilot build", @build_ref].compact.join(" ")
        body << "\n\nReply `#{build} #{first}` to build option #{first}. " \
                "Add words after the number to change that option. " \
                "Reply `#{build}` with your own approach if no option fits."
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
        return @reply_sink.call(item_id, raw) if @reply_sink
        internal = @reply_internal.nil? ? true : @reply_internal
        # The reply's id is not recorded anywhere: OpenProject::Pull#own_comment? recognises
        # opilot's own comments by their author, so there is nothing to bookkeep.
        res = @api.add_comment(item_id, comment: raw, internal: internal)
        if res.code == 201
          log_script "Note posted to WP #{wp_label(item_id)}"
        else
          log_script "Note failed for WP #{wp_label(item_id)} (HTTP #{res.code})"
        end
        res.code
      end
    end
  end
end
