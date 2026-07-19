require "json"
require "cgi"
require_relative "clients"

module Chomper
  # An inbound instruction parsed from an @chomper comment (see Pull#poll_intents).
  # `user` / `user_href` identify the commenter, so replies can address them.
  # `internal` is the trigger comment's visibility, so the reply can mirror it
  # (an internal @chomper prompt gets an internal answer, a public one a public).
  # `source` is nil for comment triggers and :assignment for a WP assigned to
  # chomper (see Pull#intent_from_assignment) — assignment intents carry no
  # comment fields, so replies are unaddressed and acked via the assignment marker.
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
    # timestamp, an assignment trigger by the once-per-WP assignment marker
    # (reusing mark_acted with the intent's nil comment_at would null out
    # last_acted_comment_at and reopen old comment triggers).
    def ack(intent)
      if intent.source == :assignment
        @pull.mark_assignment_acted(intent.item_id)
      else
        @pull.mark_acted(intent.item_id, intent.comment_at)
      end
    end

    def handle(intent)
      log_script "#{wp_label(intent.item_id)} — #{intent.command} — #{intent.subject}"
      @requester = requester_mention(intent)   # who to address in replies
      @reply_internal = intent.internal        # mirror the trigger's visibility
      case intent.command
      when :chat    then handle_chat(intent)
      when :plan    then handle_plan(intent)
      when :approve then handle_approve(intent)
      when :ship    then handle_ship(intent)
      end
    end

    private

    # An OpenProject mention of the commenter, so replies notify and address them
    # by name (falls back to the bare name, then empty, when details are missing).
    # Name and id are attacker-influenced (OpenProject display names are free
    # text), so the name is HTML-escaped and the id must be numeric.
    def requester_mention(intent)
      name = CGI.escapeHTML(intent.user.to_s)
      id   = intent.user_href.to_s.split("/").last.to_s
      return name unless id.match?(/\A\d+\z/)
      %Q(<mention class="mention" data-id="#{id}" data-type="user" data-text="#{name}">@#{name}</mention>)
    end

    # Prefix a reply with the requester mention, when known.
    def addressed(msg)
      @requester.to_s.empty? ? msg : "#{@requester} #{msg}"
    end

    # ── command handlers ──────────────────────────────────────────────────────

    def handle_chat(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
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

    def handle_plan(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      return unless produce_plan(st, intent.text) == :ok
      post_note(st.item_id, addressed(
        "here's the plan:\n\n#{st.plan_file.read.strip}\n\n" \
        "Reply `@chomper approve` to implement it, `@chomper plan <feedback>` to revise, " \
        "or `@chomper grill` to stress-test it first."))
    end

    def handle_approve(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      unless Helpers.file_has_content?(st.plan_file)
        post_note(st.item_id, addressed("there's no plan yet — comment `@chomper plan` first, or `@chomper ship` to plan and ship in one go."))
        return
      end
      ship(st)
    end

    def handle_ship(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      # Express lane: plan and ship in one pass (NEEDS_INFO still guards blind fixes).
      return unless produce_plan(st, intent.text) == :ok
      ship(st)
    end

    # ── shared steps ──────────────────────────────────────────────────────────

    # Generate (or revise) the plan for a WP. Returns :ok when plan.md is saved,
    # or :needs_info (having already posted the questions as a note).
    def produce_plan(st, feedback)
      # Planning is read-only across every repo's worktree (all mounted at
      # /repos/<name>); the branch checkout waits until #ship, once Claude has
      # chosen the target repo(s) in the plan.
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
                            related: related)
      @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file,
                      session_file: st.session_file)

      if st.plan_file.read.lstrip.start_with?("NEEDS_INFO")
        questions = st.plan_file.read.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip
        safe_rm(st.plan_file)
        log_script "Plan NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
        post_note(st.item_id, addressed("I need more information before I can plan a fix:\n\n#{questions}"))
        return :needs_info
      end

      record_chosen_repos(st)
      :ok
    end

    # Turn the saved plan into a draft PR. Idempotent/resumable: re-reports an
    # existing PR, and skips implementation when the branch already has commits.
    def ship(st)
      # Already shipped to every target repo? Re-report the existing PR links.
      if st.repos.all? { |r| Helpers.file_has_content?(st.pr_url_file(r)) }
        links = st.repos.map { |r| st.pr_url_file(r).read.strip }.join("\n")
        post_note(st.item_id, addressed("this is already shipped —\n\n#{links}"))
        return
      end

      st.repos.each { |r| checkout_branch(st, r) }

      # Implement once across every target worktree (the resumed planning session
      # carries its exploration in; --allowedTools just adds the write tools),
      # unless every target repo already holds commits from an earlier pass.
      unless st.repos.all? { |r| branch_has_commits?(st, r) }
        log_script "Implementing fix for #{wp_label(st.item_id)} in #{st.repos.map(&:name).join(", ")}"
        @claude.run(Prompts.implement(repos: repos_for_prompt(st.repos), plan: container_path(st.plan_file),
                                      resumed: session_resumable?(st)),
                    tools: Claude::TOOLS_IMPL, session_file: st.session_file)
        st.repos.each { |r| commit(st, r) }
      end

      changed = st.repos.select { |r| branch_has_commits?(st, r) }
      if changed.empty?
        log_script "#{wp_label(st.item_id)} — no changes produced, nothing to ship."
        post_note(st.item_id, addressed("I couldn't produce any changes for this — the plan may be a no-op or already applied."))
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
        suffix = failed.any? ? "\n\n(couldn't open a PR in: #{failed.map(&:name).join(", ")} — is GITHUB_CONTRIBUTOR_TOKEN set?)" : ""
        post_note(st.item_id, addressed("Here is your AI-generated prototype#{opened.size > 1 ? "s" : ""}:\n\n#{links}#{suffix}"))
      else
        post_note(st.item_id, addressed("I implemented and committed on `#{st.branch}`, but couldn't open the PR (is GITHUB_CONTRIBUTOR_TOKEN set?)."))
      end
    end

    # ── notifications ─────────────────────────────────────────────────────────

    # Replies mirror the trigger comment's visibility: an internal @chomper prompt
    # gets an internal answer, a public one a public answer. Defaults to internal
    # (the safer side) when visibility is unknown — e.g. an error before #handle
    # set @reply_internal.
    def post_note(item_id, raw)
      internal = @reply_internal.nil? ? true : @reply_internal
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
