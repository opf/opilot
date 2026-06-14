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
      filters = @pull.load_or_prompt_agent_filters
      if @ctx.allowed_emails.any?
        puts "  Allowlist active — only triggers from: #{@ctx.allowed_emails.join(", ")}"
      else
        puts "  No allowlist set (CHOMPER_ALLOWED_EMAILS) — any user can trigger @chomper."
      end
      puts "  Agent started — polling every 10s. Ctrl-C to stop."

      until Chomper.stopping?
        intents = @pull.poll_intents(filters)
        n = intents.length
        log_script "Polled #{@pull.scanned_count} work package(s) — " \
                   "#{@pull.changed_count} changed — #{n} @chomper trigger#{n == 1 ? "" : "s"}"
        intents.each do |intent|
          break if Chomper.stopping?
          handle_and_ack(intent)
        end
        sleep 10 unless Chomper.stopping?
      end
      puts "  Stopped."
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
                            plan: plan_ref, message: intent.text.to_s)
      reply = @claude.run(prompt, tools: Claude::TOOLS_READ, session_file: st.session_file)
      post_note(st.item_id, addressed(reply.strip)) unless reply.strip.empty?
    end

    def handle_plan(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      return unless produce_plan(st, intent.text) == :ok
      post_note(st.item_id, addressed(
        "here's the plan:\n\n#{st.plan_file.read.strip}\n\n" \
        "Reply `@chomper approve` to implement it, or `@chomper plan <feedback>` to revise."))
    end

    def handle_approve(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      unless st.plan_file.exist? && st.plan_file.size > 0
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
      checkout_branch(st)
      item_c = container_path(st.item_file)
      plan_c = container_path(st.plan_file)

      if feedback && !feedback.empty? && st.plan_file.exist?
        log_script "Writer: revising plan for #{wp_label(st.item_id)} from feedback"
        prompt = Prompts.replan(repo: @ctx.worktree_container, item: item_c, plan: plan_c,
                                feedback: feedback, item_id: st.item_id, title: st.subject)
        @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file,
                        session_file: st.session_file)
        return :ok
      end

      log_script "Writer: generating plan for #{wp_label(st.item_id)} — #{st.subject}"
      prompt = Prompts.plan(repo: @ctx.worktree_container, item: item_c,
                            item_id: st.item_id, title: st.subject, hint: feedback.to_s)
      @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file,
                      session_file: st.session_file)

      if st.plan_file.read.lstrip.start_with?("NEEDS_INFO")
        questions = st.plan_file.read.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip
        safe_rm(st.plan_file)
        log_script "Plan NEEDS_INFO for #{wp_label(st.item_id)} — requesting clarification."
        post_note(st.item_id, addressed("I need more information before I can plan a fix:\n\n#{questions}"))
        return :needs_info
      end

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
      if st.pr_url_file.exist? && st.pr_url_file.size > 0
        post_note(st.item_id, addressed("this is already shipped — #{st.pr_url_file.read.strip}"))
        return
      end

      checkout_branch(st)
      unless branch_has_commits?(st)
        log_script "Implementing fix for #{wp_label(st.item_id)}"
        # Resuming the planning session carries its codebase exploration into
        # implementation; --allowedTools is per-invocation, so the resumed
        # session simply gains the write tools.
        @claude.run(Prompts.implement(repo: @ctx.worktree_container, plan: container_path(st.plan_file)),
                    tools: Claude::TOOLS_IMPL, session_file: st.session_file)
        commit(st)
      end

      unless branch_has_commits?(st)
        log_script "#{wp_label(st.item_id)} — no changes produced, nothing to ship."
        post_note(st.item_id, addressed("I couldn't produce any changes for this — the plan may be a no-op or already applied."))
        return
      end

      generate_pr_description(st)
      url = @publish.open_pr(st.item_id, st.subject, st.branch)
      if url
        record_progress(st.item_id, st.branch, "shipped")
        post_note(st.item_id, addressed("here's your draft PR: [#{st.subject}](#{url})"))
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
