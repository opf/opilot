require "json"
require_relative "clients"

module Chomper
  # An inbound instruction parsed from an @chomper comment (see Pull#poll_intents).
  # `user` / `user_href` identify the commenter, so replies can address them.
  # `internal` is the trigger comment's visibility, so the reply can mirror it
  # (an internal @chomper prompt gets an internal answer, a public one a public).
  # `source` is nil for comment triggers and :developer for a WP whose Developers
  # field names chomper (see Pull#intent_from_developer) — those intents carry no
  # comment fields, so replies are unaddressed and acked via the once-per-WP marker.
  Intent = Struct.new(:item_id, :subject, :type, :command, :text, :comment_at,
                      :user, :user_href, :internal, :source, keyword_init: true)

  # How long the agent loops sleep between polling passes.
  POLL_INTERVAL = 20

  # The whole program: poll OpenProject for @chomper comments, turn each into an
  # Intent, and dispatch it through #handle. Per-WP "state" is just the files in
  # work_packages/<host>/<id>/ — plan.md present = has a plan, pr_url.txt present = shipped.
  class Agent
    include Helpers

    def initialize(ctx, pull: Pull.new(ctx), claude: Claude.new(ctx), publish: Publish.new(ctx))
      @ctx     = ctx
      @pull    = pull
      @claude  = claude
      @publish = publish
      @api     = Clients::OpenProject.new(ctx.op_url, ctx.token)
    end

    def run
      ensure_claude!
      filters = setup
      puts "  Agent started — polling every #{POLL_INTERVAL}s. Ctrl-C to stop."

      loop do
        guarded_tick("OpenProject poll") { tick(filters) }
        sleep POLL_INTERVAL
      end
    end

    # Resolve the search filters and print the allowlist banner. Returned filters
    # are passed to #tick. Split out from #run so CombinedAgent can drive the loop.
    def setup
      filters = @pull.load_or_prompt_agent_filters
      if @ctx.allowed_op_user_ids.any?
        puts "  Allowlist active — only triggers from user ids: #{@ctx.allowed_op_user_ids.join(", ")}"
      else
        puts "  No allowlist set (CHOMPER_ALLOWED_OP_USER_IDS) — any user can trigger @chomper."
      end
      filters
    end

    # One poll-and-handle pass over OpenProject @chomper triggers (no sleep).
    def tick(filters)
      log_script "Polling OpenProject (#{@ctx.op_url})…"
      intents = @pull.poll_intents(filters)
      n = intents.length
      log_script "Polled #{@pull.scanned_count} work package(s) — " \
                 "#{@pull.changed_count} changed — #{n} @chomper trigger#{n == 1 ? "" : "s"}"
      intents.each { |intent| handle_and_ack(intent) }
    end

    # Handle one intent, then mark its trigger acted. A *handled* error (raised
    # and caught here) is logged and still acked, so a permanent failure — e.g. a
    # denied push — is not replayed every poll. We do NOT post an error note to
    # the WP: a transient failure (e.g. a Claude error_during_execution) would
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

    # Route act-state to the trigger's source: a comment trigger is keyed by its
    # timestamp, a Developers trigger by the once-per-WP marker (reusing
    # mark_acted with the intent's nil comment_at would null out
    # last_acted_comment_at and reopen old comment triggers).
    def ack(intent)
      if intent.source == :developer
        @pull.mark_developer_acted(intent.item_id)
      else
        @pull.mark_acted(intent.item_id, intent.comment_at)
      end
    end

    def handle(intent)
      log_script "#{wp_label(intent.item_id)} — #{intent.command} — #{intent.subject}"
      @requester = requester_mention(intent)   # who to address in replies
      @reply_internal = intent.internal        # mirror the trigger's visibility
      case intent.command
      when :chat then handle_chat(intent)
      when :ship then handle_ship(intent)
      end
    end

    private

    # An OpenProject mention of the commenter, so replies notify and address them
    # by name. Empty for a Developers handover, which carries no commenter.
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
                            related: related_ref(st))
      reply = @claude.run(prompt, tools: Claude::TOOLS_READ, session_file: st.session_file)
      post_note(st.item_id, addressed(reply.strip)) unless reply.strip.empty?
    end

    # The one working intent: plan, implement, and open the prototype.
    #
    # This is where every trigger lands — `@chomper build` (alias `fix`) and a
    # Developers handover. There is no
    # separate plan-and-wait command any more: a fix with more than one defensible
    # shape stops and offers numbered options (Prompts::OPTIONS_CONTRACT), and a
    # fix with one shape is planned and shipped in the same call — so a simple
    # ticket costs exactly what it did before. NEEDS_INFO still guards blind fixes.
    # Once a prototype exists the work moves to the pull request and this handler
    # only points there (#report_shipped).
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
      #    This is what the retired `approve` did, and the only way to get a
      #    prototype of the exact plan a human has already read.
      return ship(st) if Helpers.file_has_content?(st.plan_file) && direction.empty?

      # 3. An offer is standing and the reply names no option: post the same list
      #    again (no Claude call), because the question is still the question.
      if direction.empty? && Helpers.file_has_content?(st.options_file)
        post_options(st, intent)
        return
      end

      # 4. Nothing has settled the approach: this is the one call that may ask.
      case produce_plan(st, direction, allow_options: direction.empty?)
      when :options then post_options(st, intent)
      when :ok      then ship(st)
      end
    end

    # ── shared steps ──────────────────────────────────────────────────────────

    # Generate (or revise) the plan for a WP. Returns :ok when plan.md is saved,
    # :needs_info (having already posted the questions as a note), or :options
    # when the writer answered with implementation options instead of a plan
    # (options.json written, the comment left to the caller).
    #
    # `allow_options:` is the caller's judgment that no human has picked an
    # approach yet; the writer's judgment is whether the fix really has more than
    # one shape (Prompts::OPTIONS_CONTRACT). `:failed` means the call produced
    # neither, and is handled like any other failed run — logged, never commented.
    def produce_plan(st, feedback, allow_options: false, retry_bad_options: true)
      # Planning is read-only across every repo's worktree (all mounted at
      # /repos/<name>); the branch checkout waits until #ship, once Claude has
      # chosen the target repo(s) in the plan.
      #
      # Every repo is synced, not just the eventual targets: which repos the fix
      # lands in is the plan's own output, so at this point there is nothing
      # narrower to sync, and Claude reads across the registry to decide.
      sync_bases_for_reading(@ctx.repos.all)
      item_c  = container_path(st.item_file)
      plan_c  = container_path(st.plan_file)
      related = related_ref(st)
      menu    = repos_for_prompt(@ctx.repos.all)

      if feedback && !feedback.empty? && st.plan_file.exist?
        log_script "Writer: revising plan for #{wp_label(st.item_id)} from feedback"
        prompt = Prompts.replan(repos_summary: @ctx.repos.summary, repos: menu, item: item_c, plan: plan_c,
                                feedback: feedback, item_id: st.item_id, title: st.subject,
                                resumed: session_resumable?(st), related: related)
        @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file,
                        session_file: st.session_file)
        record_chosen_repos(st)
        return :ok
      end

      log_script "Writer: generating plan for #{wp_label(st.item_id)} — #{st.subject}"
      prompt = Prompts.plan(repos_summary: @ctx.repos.summary, repos: menu, item: item_c,
                            item_id: st.item_id, title: st.subject, hint: feedback.to_s,
                            related: related, allow_options: allow_options)
      @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file,
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
        options = Helpers.parse_options(st.plan_file.read)
        safe_rm(st.plan_file)                    # the file holds options, never a plan
        if allow_options && options.length > 1
          st.options_file.write("#{JSON.pretty_generate(options)}\n")
          log_script "Options offered for #{wp_label(st.item_id)} — #{options.length}"
          return :options
        end
        unless retry_bad_options
          log_script "#{wp_label(st.item_id)} — the writer answered with options twice; no plan produced."
          return :failed
        end
        # A single option, an unusable list, or options nobody asked for: ask once
        # more for a plan. Bounded to one retry, so a writer that keeps answering
        # with options ends the trigger instead of looping.
        log_script "Unusable OPTIONS for #{wp_label(st.item_id)} — asking for one plan instead."
        return produce_plan(st, feedback, retry_bad_options: false)
      end

      record_chosen_repos(st)
      :ok
    end

    # ── implementation options ────────────────────────────────────────────────

    # The plan-prompt focus for an option the reporter selected, or nil when the
    # comment names no saved option (it is then plain direction).
    def option_focus(st, text)
      Helpers.option_choice(Helpers.safe_json_read(st.options_file) || [], text)
    end

    # Post the offered options as one work-package comment.
    #
    # Composed here rather than by Claude so the wording, the numbering and the
    # reply instructions are the same every time, and so no heading or sign-off
    # can reach the activity tab; the writer supplies only the title and the
    # sentence. A Developers handover addresses nobody (the intent carries no
    # commenter), so its offer is posted publicly instead — an internal comment
    # that mentions nobody reaches nobody who can answer it.
    def post_options(st, intent)
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
      body << "\n\nReply `@chomper build #{first}` to build option #{first}. " \
              "Add words after the number to change that option. " \
              "Reply `@chomper build` with your own approach if no option fits."
      body << "\n\nOnly a user on chomper's allowlist can select an option." if @ctx.allowed_op_user_ids.any?

      post_note(st.item_id, addressed(body), internal: intent.source == :developer ? false : nil)
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
    # code happens on the pull request, where chomper reads comments and pushes
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

      st.repos.each { |r| checkout_branch(st, r) }

      # Implement once across every target worktree (the resumed planning session
      # carries its exploration in; --allowedTools just adds the write tools),
      # unless every target repo already holds commits from an earlier pass.
      unless st.repos.all? { |r| branch_has_commits?(st, r) }
        log_script "Implementing #{wp_label(st.item_id)} in #{st.repos.map(&:name).join(", ")}"
        @claude.run(Prompts.implement(repos: repos_for_prompt(st.repos), plan: container_path(st.plan_file),
                                      resumed: session_resumable?(st)),
                    tools: Claude::TOOLS_IMPL, session_file: st.session_file)
        st.repos.each { |r| commit(st, r) }
      end

      changed = st.repos.select { |r| branch_has_commits?(st, r) }
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
        links = opened.map { |repo, url| "- [#{st.subject} → `#{repo.name}`](#{url})" }.join("\n")
        suffix = failed.any? ? "\n\n(I could not open a PR in: #{failed.map(&:name).join(", ")}. Make sure GITHUB_CONTRIBUTOR_TOKEN is set.)" : ""
        post_note(st.item_id, addressed("Here is your AI-generated prototype#{opened.size > 1 ? "s" : ""}:\n\n#{links}#{suffix}"))
      else
        post_note(st.item_id, addressed("I implemented the change and committed it on `#{st.branch}`. I could not open the PR. Make sure GITHUB_CONTRIBUTOR_TOKEN is set."))
      end
    end

    # ── notifications ─────────────────────────────────────────────────────────

    # Replies mirror the trigger comment's visibility: an internal @chomper prompt
    # gets an internal answer, a public one a public answer. Defaults to internal
    # (the safer side) when visibility is unknown — e.g. an error before #handle
    # set @reply_internal. `internal:` overrides that for the one comment that
    # must reach a reader the trigger cannot name (see #post_options).
    def post_note(item_id, raw, internal: nil)
      internal = @reply_internal.nil? ? true : @reply_internal if internal.nil?
      code, body = @api.post_activity(item_id, comment: raw, internal: internal)
      if code == 201
        log_script "Note posted to WP #{wp_label(item_id)}"
        comment_id = body&.dig("id")&.to_s
        @pull.record_chomper_comment(item_id, comment_id) if comment_id
      else
        log_script "Note failed for WP #{wp_label(item_id)} (HTTP #{code})"
      end
      code
    end
  end
end
