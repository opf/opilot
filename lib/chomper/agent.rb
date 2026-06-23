require "json"
require "cgi"
require_relative "clients"

module Chomper
  # An inbound instruction parsed from an @chomper comment (see Pull#poll_intents).
  # `user` / `user_href` identify the commenter, so replies can address them.
  Intent = Struct.new(:item_id, :subject, :type, :command, :text, :comment_at,
                      :user, :user_href, keyword_init: true)

  # Cooperative shutdown flag, shared with the SIGINT handler in bin/chomper.
  # The agent loop checks it between items so Ctrl-C finishes the current intent
  # rather than tearing partial state; a second Ctrl-C force-exits.
  @stop = false
  def self.request_stop; @stop = true; end
  def self.stopping?;    @stop; end

  # The whole program: poll OpenProject for @chomper comments, turn each into an
  # Intent, and dispatch it through #handle. Per-WP "state" is just the files in
  # items/<id>/ — plan.md present = has a plan, pr_url.txt present = shipped.
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
      puts "  Agent started — polling every 10s. Ctrl-C to stop."

      until Chomper.stopping?
        tick(filters)
        sleep 10 unless Chomper.stopping?
      end
      puts "  Stopped."
    end

    # Resolve the search filters and print the allowlist banner. Returned filters
    # are passed to #tick. Split out from #run so CombinedAgent can drive the loop.
    def setup
      filters = @pull.load_or_prompt_agent_filters
      if @ctx.allowed_emails.any?
        puts "  Allowlist active — only triggers from: #{@ctx.allowed_emails.join(", ")}"
      else
        puts "  No allowlist set (CHOMPER_ALLOWED_EMAILS) — any user can trigger @chomper."
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
      intents.each do |intent|
        break if Chomper.stopping?
        handle_and_ack(intent)
      end
    end

    # Handle one intent, then mark its trigger acted. A *handled* error (raised
    # and caught here) is reported to the WP and still acked, so a permanent
    # failure — e.g. a denied push — is not replayed every poll. Only a hard
    # crash (uncaught, so `ensure` never runs) leaves the trigger for the next
    # poll to retry.
    def handle_and_ack(intent)
      handle(intent)   # sets @requester as its first step
    rescue => e
      log_script "Error on #{wp_label(intent.item_id)} (#{intent.command}): #{e.message}"
      post_note(intent.item_id, addressed("sorry — I hit an error handling `@chomper #{intent.command}`:\n\n#{e.message}")) rescue nil
    ensure
      @pull.mark_acted(intent.item_id, intent.comment_at)
    end

    def handle(intent)
      log_script "#{wp_label(intent.item_id)} — #{intent.command} — #{intent.subject}"
      @requester = requester_mention(intent)   # who to address in replies
      case intent.command
      when :chat    then handle_chat(intent)
      when :plan    then handle_plan(intent)
      when :approve then handle_approve(intent)
      when :fix     then handle_fix(intent)
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
      if @ctx.auto_plan_approval?
        post_note(st.item_id, addressed(
          "here's the plan:\n\n#{st.plan_file.read.strip}\n\nAUTO_PLAN_APPROVAL is set — implementing it now."))
        ship(st)
      else
        post_note(st.item_id, addressed(
          "here's the plan:\n\n#{st.plan_file.read.strip}\n\n" \
          "Reply `@chomper approve` to implement it, or `@chomper plan <feedback>` to revise."))
      end
    end

    def handle_approve(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      unless Helpers.file_has_content?(st.plan_file)
        post_note(st.item_id, addressed("there's no plan yet — comment `@chomper plan` first, or `@chomper fix` to plan and ship in one go."))
        return
      end
      ship(st)
    end

    def handle_fix(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      # Express lane: skip the internal reviewer (NEEDS_INFO still guards blind fixes).
      return unless produce_plan(st, intent.text, review: false) == :ok
      ship(st)
    end

    # ── shared steps ──────────────────────────────────────────────────────────

    # Generate (or revise) the plan for a WP. Returns :ok when plan.md is saved,
    # or :needs_info / :rejected (having already posted the explanatory note).
    # `review: false` skips the internal reviewer pass (used by the fix express lane).
    def produce_plan(st, feedback, review: true)
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

      return :ok unless review && @ctx.plan_review?   # reviewer is opt-in; human approval is the gate

      log_script "Reviewer: checking plan for #{wp_label(st.item_id)}"
      review_prompt = Prompts.plan_review(plan: plan_c, item_id: st.item_id)
      # Deliberately no session_file: the reviewer must judge the plan without
      # inheriting the writer's exploration context.
      @claude.capture(review_prompt, tools: Claude::TOOLS_READ, outfile: st.review_file)
      verdict = st.review_file.read.scan(/\b(PROCEED|REVISE|REJECT)\b/i).last&.first&.upcase || "PROCEED"

      case verdict
      when "REJECT"
        issues = st.review_file.read.strip
        safe_rm(st.review_file, st.plan_file)
        log_script "Plan REJECTED for #{wp_label(st.item_id)}."
        post_note(st.item_id, addressed("I don't think this is safe to fix as specified:\n\n#{issues}"))
        return :rejected
      when "REVISE"
        log_script "Revising plan for #{wp_label(st.item_id)} from reviewer feedback"
        revise_prompt = Prompts.plan_revise(plan: plan_c, review: container_path(st.review_file))
        @claude.capture(revise_prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file,
                        session_file: st.session_file)
      end

      safe_rm(st.review_file)
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
        suffix = failed.any? ? "\n\n(couldn't open a PR in: #{failed.map(&:name).join(", ")} — is GITHUB_TOKEN set?)" : ""
        post_note(st.item_id, addressed("here's your draft PR#{opened.size > 1 ? "s" : ""}:\n\n#{links}#{suffix}"))
      else
        post_note(st.item_id, addressed("I implemented and committed on `#{st.branch}`, but couldn't open the PR (is GITHUB_TOKEN set?)."))
      end
    end

    # ── notifications ─────────────────────────────────────────────────────────

    def post_note(item_id, raw)
      code, body = @api.post_activity(item_id, comment: raw)
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
