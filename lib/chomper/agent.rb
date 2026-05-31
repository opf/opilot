require "json"
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

    ItemState = Struct.new(:item_id, :subject, :branch, :item_dir, :plan_file,
                           :item_file, :review_file, :pr_desc_file, :pr_url_file,
                           :session_file, keyword_init: true)

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
      log_script "Error on ##{intent.item_id} (#{intent.command}): #{e.message}"
      post_note(intent.item_id, addressed("sorry — I hit an error handling `@chomper #{intent.command}`:\n\n#{e.message}")) rescue nil
    ensure
      @pull.mark_acted(intent.item_id, intent.comment_at)
    end

    def handle(intent)
      log_script "##{intent.item_id} — #{intent.command} — #{intent.subject}"
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
    def requester_mention(intent)
      name = intent.user.to_s
      id   = intent.user_href.to_s.split("/").last.to_s
      return name if id.empty?
      %Q(<mention class="mention" data-id="#{id}" data-type="user" data-text="#{name}">@#{name}</mention>)
    end

    # Prefix a reply with the requester mention, when known.
    def addressed(msg)
      @requester.to_s.empty? ? msg : "#{@requester} #{msg}"
    end

    # ── command handlers ──────────────────────────────────────────────────────

    def handle_chat(intent)
      st = state_for(intent.item_id, intent.subject, intent.type)
      plan_text = st.plan_file.exist? ? st.plan_file.read : "(no plan yet)"
      prompt = Prompts.chat(item_id: st.item_id, subject: st.subject,
                            item: container_path(st.item_file),
                            plan: plan_text, message: intent.text.to_s)
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
        log_script "Writer: revising plan for ##{st.item_id} from feedback"
        prompt = Prompts.replan(repo: @ctx.worktree_container, item: item_c, plan: plan_c,
                                feedback: feedback, item_id: st.item_id, title: st.subject)
        @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file)
        return :ok
      end

      log_script "Writer: generating plan for ##{st.item_id} — #{st.subject}"
      prompt = Prompts.plan(repo: @ctx.worktree_container, item: item_c,
                            item_id: st.item_id, title: st.subject, hint: feedback.to_s)
      @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file)

      if st.plan_file.read.lstrip.start_with?("NEEDS_INFO")
        questions = st.plan_file.read.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip
        safe_rm(st.plan_file)
        log_script "Plan NEEDS_INFO for ##{st.item_id} — requesting clarification."
        post_note(st.item_id, addressed("I need more information before I can plan a fix:\n\n#{questions}"))
        return :needs_info
      end

      return :ok unless review   # express lane: skip the reviewer

      log_script "Reviewer: checking plan for ##{st.item_id}"
      review_prompt = Prompts.plan_review(plan: plan_c, item_id: st.item_id)
      @claude.capture(review_prompt, tools: Claude::TOOLS_READ, outfile: st.review_file)
      verdict = st.review_file.read.scan(/\b(PROCEED|REVISE|REJECT)\b/i).last&.first&.upcase || "PROCEED"

      case verdict
      when "REJECT"
        issues = st.review_file.read.strip
        safe_rm(st.review_file, st.plan_file)
        log_script "Plan REJECTED for ##{st.item_id}."
        post_note(st.item_id, addressed("I don't think this is safe to fix as specified:\n\n#{issues}"))
        return :rejected
      when "REVISE"
        log_script "Revising plan for ##{st.item_id} from reviewer feedback"
        revise_prompt = Prompts.plan_revise(plan: plan_c, review: container_path(st.review_file))
        @claude.capture(revise_prompt, tools: Claude::TOOLS_READ, outfile: st.plan_file)
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
        log_script "Implementing fix for ##{st.item_id}"
        @claude.run(Prompts.implement(repo: @ctx.worktree_container, plan: container_path(st.plan_file)),
                    tools: Claude::TOOLS_IMPL)
        commit(st)
      end

      unless branch_has_commits?(st)
        log_script "##{st.item_id} — no changes produced, nothing to ship."
        post_note(st.item_id, addressed("I couldn't produce any changes for this — the plan may be a no-op or already applied."))
        return
      end

      generate_pr_description(st)
      url = @publish.open_pr(st.item_id, st.subject, st.branch)
      if url
        record_progress(st.item_id, st.branch, "shipped")
        pr_title = "[##{st.item_id}] #{st.subject}"
        post_note(st.item_id, addressed("here's your draft PR: [#{pr_title}](#{url})"))
      else
        post_note(st.item_id, addressed("I implemented and committed on `#{st.branch}`, but couldn't open the PR (is GITHUB_TOKEN set?)."))
      end
    end

    # ── git / worktree mechanics ────────────────────────────────────────────

    def checkout_branch(st)
      if local_branch_exists?(worktree, st.branch)
        worktree.checkout(st.branch)
      else
        worktree.checkout(st.branch, new_branch: true, start_point: 'origin/dev')
      end
    end

    def branch_has_commits?(st)
      worktree.log.between('origin/dev', st.branch).execute.any?
    end

    def commit(st)
      worktree.add(all: true)
      diff = worktree.diff('HEAD')
      return if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      worktree.commit("fix: #{st.subject} (WP ##{st.item_id})")
      c = worktree.log(1).first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"
      record_progress(st.item_id, st.branch, "committed")
    end

    def generate_pr_description(st)
      return if st.pr_desc_file.exist? && st.pr_desc_file.size > 0
      template_file    = @ctx.repo_path / ".github" / "pull_request_template.md"
      template_section = template_file.exist? ? "Fill in this PR template exactly: #{template_file}" : ""
      diff_stat = worktree.diff('HEAD~1', 'HEAD').stats[:files]
        .map { |f, s| "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        .join("\n")
      prompt = Prompts.pr_description(
        item: container_path(st.item_file), plan: container_path(st.plan_file),
        diff_stat: diff_stat, template_section: template_section
      )
      pr_text = @claude.run(prompt, tools: Claude::TOOLS_READ)
      pr_body = pr_text[/^#.*/m] || pr_text
      st.pr_desc_file.write(strip_ansi(pr_body))
    end

    # ── helpers ───────────────────────────────────────────────────────────────

    def state_for(item_id, subject, type = nil)
      dir = @ctx.state_dir / "items" / item_id.to_s
      dir.mkpath
      ItemState.new(
        item_id:      item_id.to_s,
        subject:      subject.to_s,
        branch:       branch_slug(item_id, type.to_s, subject.to_s),
        item_dir:     dir,
        plan_file:    dir / "plan.md",
        item_file:    dir / "item.json",
        review_file:  dir / "review.txt",
        pr_desc_file: dir / "pr.md",
        pr_url_file:  dir / "pr_url.txt",
        session_file: dir / "session_id"
      )
    end

    def container_path(host_path)
      host_path.to_s.sub(@ctx.state_dir.to_s, @ctx.state_container)
    end

    def post_note(item_id, raw)
      code, = @api.post_activity(item_id, comment: raw)
      log_script(code == 201 ? "Note posted to WP ##{item_id}" : "Note failed for WP ##{item_id} (HTTP #{code})")
      code
    end
  end
end
