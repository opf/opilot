require "json"

module OPilot
  module GitHub
    # Polls opilot's own PRs (reply and push) and upstream PRs that mention opilot
    # (`reply_only`). It never merges. See CLAUDE.md, gh-agent.
    class Agent
      include Helpers

      def initialize(ctx, pull: GitHub::Pull.new(ctx), upstream_pull: GitHub::UpstreamPull.new(ctx),
                     harness: Harness.new(ctx), github: Clients::GitHub.new(ctx.contributor_token),
                     pr_runner: nil)
        @ctx           = ctx
        @pull          = pull
        @upstream_pull = upstream_pull
        @harness        = harness
        @github        = github
        @pr_runner     = pr_runner
      end

      def run
        unless @ctx.contributor_token
          puts "  Error: GITHUB_CONTRIBUTOR_TOKEN is not set — gh-agent acts as the bot account and needs its token."
          return
        end
        ensure_harness!
        scan_from_at = setup
        puts "  gh-agent started — polling #{sources} every #{POLL_INTERVAL}s. Ctrl-C to stop."

        loop do
          guarded_tick("PR poll") { tick(scan_from_at) }
          sleep POLL_INTERVAL
        end
      end

      # Split out from #run so CombinedAgent can drive the loop.
      def setup
        scan_from_at = prompt_scan_from
        report_mcp_status
        if @ctx.allowed_gh_users.any?
          puts "  Allowlist active — only @opilot from: #{@ctx.allowed_gh_users.map { |u| "@#{u}" }.join(", ")}"
        else
          puts "  No allowlist set (OPILOT_ALLOWED_GH_USERS) — any GitHub user can trigger @opilot on opilot's own PRs."
        end
        # Name the state: "scanned nothing" and "not scanning" look alike in the log.
        if @upstream_pull.enabled?
          puts "  Tracking upstream PRs for @opilot mentions — #{@ctx.repos.all.map(&:upstream).join(", ")}."
        elsif @ctx.track_upstream_prs?
          puts "  Upstream PR tracking requested but OFF — it also needs OPILOT_ALLOWED_GH_USERS."
        else
          puts "  Upstream PR tracking off — opilot's own PRs only (set OPILOT_TRACK_UPSTREAM_PRS=1)."
        end
        scan_from_at
      end

      def sources
        @upstream_pull.enabled? ? "opilot + upstream PRs" : "opilot's own PRs"
      end

      def tick(scan_from_at)
        intents = @pull.poll_intents(scan_from_at) + @upstream_pull.poll_intents(scan_from_at)
        ci      = intents.count { |i| i.kind == :ci }
        trig    = intents.length - ci
        summary = "#{trig} @opilot trigger#{trig == 1 ? "" : "s"}"
        summary += ", #{ci} CI fix#{ci == 1 ? "" : "es"}"
        scanned = "#{@pull.scanned_count} opilot PR(s)"
        scanned += " + #{@upstream_pull.scanned_count} upstream PR(s)" if @upstream_pull.enabled?
        log_script "Polled #{sources} — #{scanned} — #{summary}"
        intents.each { |intent| handle_and_ack(intent) }
      end

      # A handled error is reported and acked. A Ctrl-C (SystemExit) passes the
      # rescue, so it posts nothing and leaves the comment for the next poll.
      def handle_and_ack(intent)
        handle(intent)
        mark_acted(intent)
      rescue => e
        log_script "Error on #{intent.repo}##{intent.pr_number}: #{e.class}: #{e.message}"
        post_reply(intent, "I could not handle that comment. The error is:\n\n#{e.message}") rescue nil
        mark_acted(intent)
      end

      def handle(intent)
        if intent.kind == :ci
          log_script "#{intent.repo}##{intent.pr_number} — CI failed on #{intent.head_sha.to_s[0, 7]}"
          return handle_ci(intent)
        end
        # `close` comes before the spec branch, or "close this" on a spec PR would
        # push a spec edit. See CLAUDE.md, gh-agent.
        if intent.command == :close && !intent.reply_only
          log_script "#{intent.repo}##{intent.pr_number} — @#{intent.user_login} asked to close it"
          return handle_close(intent)
        end
        if intent.spec?
          log_script "#{intent.repo}##{intent.pr_number} — @#{intent.user_login} on spec #{intent.spec_change_id}"
          return handle_spec(intent)
        end
        if intent.command == :refresh && !intent.reply_only
          log_script "#{intent.repo}##{intent.pr_number} — @#{intent.user_login} asked for a refresh"
          return handle_refresh(intent)
        end
        kind = intent.reply_only ? "#{intent.kind} comment, review-only" : "#{intent.kind} comment"
        log_script "#{intent.repo}##{intent.pr_number} — @#{intent.user_login} (#{kind})"
        intent.reply_only ? handle_review(intent) : handle_own(intent)
      end

      # An upstream PR: read-only fetch, answered in text. Never commits or pushes.
      def handle_review(intent)
        repo         = @ctx.repos.by_upstream(intent.repo)
        dir          = @upstream_pull.pr_dir(intent.repo, intent.pr_number)
        pr_file      = dir / "pr.json"
        ci_file      = dir / "ci.json"
        session_file = dir / "gh_session_id"

        @github.fetch_branch(head_repo(intent), branch: intent.branch, worktree_path: repo.worktree_host)
        checkout_pr_branch(repo, intent.branch)

        prompt = Prompts::PrAdvisor.pr_review(
          repo: intent.repo, pr_number: intent.pr_number, title: intent.subject,
          worktree: repo.worktree_container, base: repo.base, pr_thread: container_path(pr_file),
          comment: intent.text.to_s, author: intent.user_login.to_s,
          comment_id: intent.comment_id, in_reply_to: intent.in_reply_to,
          ci: review_ci_ref(ci_file, intent.head_sha)
        )
        reply = llm(:pr_advisor, prompt, session_file: session_file)
        post_suggestions(intent, reply)
        post_reply(intent, reply)
      end

      # Best-effort: a bad line range 422s the whole review, and the prose reply
      # still carries the details.
      def post_suggestions(intent, reply)
        comments = parse_suggestions(reply)
        return if comments.empty? || intent.head_sha.to_s.empty?
        @github.create_review(
          intent.repo, intent.pr_number, commit_id: intent.head_sha,
          body: "🤖 Suggested changes. Click **Apply suggestion** on each one to commit it to your branch.",
          comments: comments
        )
        log_script "Posted #{comments.length} suggestion(s) on #{intent.repo}##{intent.pr_number}"
      rescue => e
        log_script "Suggestions failed on #{intent.repo}##{intent.pr_number} (posting reply only): #{e.message}"
      end

      # The SUGGESTIONS block before the REPLY line. Bad JSON yields none.
      def parse_suggestions(text)
        seg = text.to_s.split(/^\s*REPLY:/m, 2).first.to_s
        raw = seg[/SUGGESTIONS:\s*(.+)/m, 1] or return []
        json = raw[/```(?:json)?\s*(.*?)```/m, 1] || raw
        Array(JSON.parse(json.strip)).filter_map do |s|
          next unless s.is_a?(Hash)
          path = s["path"].to_s
          line = s["line"]
          code = s["suggestion"].to_s
          next if path.empty? || !line.is_a?(Integer) || code.empty?
          c = { path: path, line: line, side: "RIGHT", body: "```suggestion\n#{code}\n```" }
          if (sl = s["start_line"]).is_a?(Integer) && sl < line
            c[:start_line] = sl
            c[:start_side]  = "RIGHT"
          end
          c
        end
      rescue JSON::ParserError
        []
      end

      # Checks the head SHA, so a failure cached for an earlier commit is not shown.
      def review_ci_ref(ci_file, head_sha)
        return nil if head_sha.to_s.empty?
        data = Helpers.safe_json_read(ci_file)
        return nil unless data && data["head_sha"].to_s == head_sha.to_s
        container_path(ci_file)
      end

      # `item_ref`/`plan_ref` already hold the placeholder for a missing file.
      OwnPrPaths = Struct.new(:repo, :pr_file, :ci_file, :session_file, :item_ref, :plan_ref,
                              keyword_init: true)

      def own_pr_paths(intent)
        pr_dir = Helpers.item_dir(@ctx, intent.item_id) / "repos" / intent.repo_name
        item_ref, plan_ref = item_refs(intent.item_id)
        OwnPrPaths.new(
          repo:         @ctx.repos.by_upstream(intent.repo),
          pr_file:      pr_dir / "pr.json",
          ci_file:      pr_dir / "ci.json",
          session_file: pr_dir / "gh_session_id",
          item_ref:     item_ref,
          plan_ref:     plan_ref
        )
      end

      # Shared by #handle_own and #handle_ci; the block builds the prompt. The head
      # is fetched over HTTPS from the fork. No change means nothing is pushed.
      def run_on_pr_head(intent)
        paths = own_pr_paths(intent)
        @github.fetch_branch(head_repo(intent), branch: intent.branch,
                             worktree_path: paths.repo.worktree_host)
        checkout_pr_branch(paths.repo, intent.branch)

        reply = llm(:pr_author, yield(paths), session_file: paths.session_file)
        reply = publisher.apply_description(intent.repo, intent.pr_number, reply)

        post_reply(intent, reply)
        push_followup(intent, paths.repo) if commit_followup(intent, paths.repo)
      end

      def handle_own(intent)
        run_on_pr_head(intent) do |p|
          Prompts::PrAuthor.gh_reply(
            worktree: p.repo.worktree_container, repo: intent.repo, pr_number: intent.pr_number,
            title: intent.subject, item: p.item_ref, plan: p.plan_ref,
            pr_thread: container_path(p.pr_file), comment: intent.text.to_s,
            author: intent.user_login.to_s, comment_id: intent.comment_id, in_reply_to: intent.in_reply_to,
            op_mcp: op_mcp_live?
          )
        end
      end

      def handle_ci(intent)
        run_on_pr_head(intent) do |p|
          Prompts::PrAuthor.fix_ci(
            op_mcp: op_mcp_live?,
            worktree: p.repo.worktree_container, repo: intent.repo, pr_number: intent.pr_number,
            title: intent.subject, item: p.item_ref, plan: p.plan_ref,
            pr_thread: container_path(p.pr_file), ci: container_path(p.ci_file)
          )
        end
      end

      def publisher
        @publisher ||= GitHub::Publish.new(@ctx, github: @github)
      end

      # The base merge is forced: the trigger comment just bumped updated_at, so
      # the quiet-day rule would always skip it. Runners::Pr posts its own summary.
      def handle_refresh(intent)
        pr_runner.refresh_one(intent.item_id, intent.repo_name)
      end

      # Close first, reply second, so the reply states a done fact. The next poll
      # sets `pr_done`, as for a human close. See CLAUDE.md, gh-agent.
      def handle_close(intent)
        @github.close_pr(intent.repo, intent.pr_number)
        log_script "Closed #{intent.repo}##{intent.pr_number}"
        post_reply(intent, "I closed this pull request without a merge, as @#{intent.user_login} asked. " \
                           "Reopen it if you need the work again.")
      end

      # A comment on a `pd` proposal PR revises the spec. The branch is on the
      # bot's fork, so the push needs no confirmation.
      def handle_spec(intent)
        repo    = @ctx.repos[intent.repo_name] || @ctx.default_repo
        dir     = @pull.pr_dir(intent.item_id, intent.repo_name, spec: true)
        pr_file = dir / "pr.json"

        @github.fetch_branch(head_repo(intent), branch: intent.branch, worktree_path: repo.worktree_host)
        checkout_pr_branch(repo, intent.branch)

        reply = product_runner.revise_proposal(
          intent.spec_change_id,
          comment_section: Prompts.comment_section(
            comment_id: intent.comment_id, author: intent.user_login.to_s,
            comment: intent.text.to_s, in_reply_to: intent.in_reply_to
          ),
          pr_thread: container_path(pr_file),
          session_file: dir / "gh_session_id",
          repo_name: intent.repo_name
        )

        post_reply(intent, reply)
        push_followup(intent, repo) if spec_commit_pending?(repo, intent.branch)
      end

      # revise_proposal commits itself, because the spec tree needs a force-add.
      def spec_commit_pending?(repo, branch)
        worktree(repo).log.between("FETCH_HEAD", branch).execute.any?
      rescue StandardError
        false
      end

      private

      # Built lazily and without a PD::Intake: revising a proposal never reads a
      # document, and Intake would drag roo/nokogiri into every gh-agent run.
      def product_runner
        @product_runner ||= PD::Runner.new(@ctx, harness: @harness)
      end

      # Built lazily: only a refresh needs it.
      def pr_runner
        @pr_runner ||= Runners::Pr.new(@ctx, harness: @harness, github: @github,
                                    gh_pull: @pull, interactive: false)
      end

      def prompt_scan_from
        previous = saved_scan_from_at
        print %(  How far back should the PR comment scanner look? (e.g. "2h", "3 days", "1 week", "1 month")\n  Scan from [#{previous || "now"}]: )
        reply = $stdin.gets.to_s.chomp
        scan_from_at = (previous && reply.strip.empty?) ? previous : Helpers.parse_scan_from(reply)
        save_scan_from_at(scan_from_at)
        scan_from_at
      end

      # Saved so the next run offers it as the default.
      def scan_from_path
        @ctx.state_dir / "gh_agent_scan_from.json"
      end

      def saved_scan_from_at
        (Helpers.safe_json_read(scan_from_path) || {})["scan_from_at"]
      end

      def save_scan_from_at(scan_from_at)
        Helpers.write_json_atomic(scan_from_path, { "scan_from_at" => scan_from_at }, "gh_scan_from")
      rescue StandardError => e
        log_script "Warning: could not save scan-from window: #{e.message}"
      end

      # Records our comment id so it does not trigger again.
      def post_reply(intent, body)
        text = Helpers.extract_reply(body)
        return if text.empty?
        text = "🤖 #{text}"
        comment =
          if intent.kind == :review
            @github.reply_to_review_comment(intent.repo, intent.pr_number, text, intent.comment_id)
          else
            @github.add_issue_comment(intent.repo, intent.pr_number, text)
          end
        log_script "Replied on #{intent.repo}##{intent.pr_number}"
        record_reply(intent, comment&.id)
      rescue => e
        log_script "Reply failed on #{intent.repo}##{intent.pr_number}: #{e.message}"
      end

      def mark_acted(intent)
        if intent.kind == :ci
          # CI dedup is per-SHA, not by comment timestamp.
          @pull.mark_ci_acted(intent.item_id, intent.repo_name, intent.head_sha)
        elsif intent.reply_only
          @upstream_pull.mark_acted(intent.repo, intent.pr_number, intent.comment_at)
        else
          @pull.mark_acted(intent.item_id, intent.repo_name, intent.comment_at, spec: intent.spec?)
        end
      end

      def record_reply(intent, comment_id)
        if intent.reply_only
          @upstream_pull.record_opilot_comment(intent.repo, intent.pr_number, comment_id)
        else
          @pull.record_opilot_comment(intent.item_id, intent.repo_name, comment_id, spec: intent.spec?)
        end
      end

      # Returns false when the LLM changed no file.
      def commit_followup(intent, repo)
        Helpers.adopt_github_author!(@ctx.contributor_token)
        wt   = worktree(repo)
        diff = stage_all(wt)
        return false unless diff
        commit_and_log(wt, feedback_commit_message(intent, diff))
        record_progress(intent.item_id, intent.branch, "gh-commit")
        true
      end

      def feedback_commit_message(intent, diff)
        label   = wp_label(intent.item_id)
        subject = generate_commit_subject(diff)
        subject.empty? ? "[#{label}] address PR feedback" : "[#{label}] #{subject}"
      end

      # No confirmation: the head is the bot's fork. A canonical head (an adopted
      # PR) is refused.
      def push_followup(intent, repo)
        target = head_repo(intent)
        if refuse_canonical_push?(target, intent.branch)
          log_script "PR ##{intent.pr_number} not updated (the commit stays in the clone)."
          return
        end
        @github.push_branch(target, branch: intent.branch, worktree_path: repo.worktree_host)
        log_script "Pushed to #{target} — PR ##{intent.pr_number} updated."
      end

      # Falls back to the base repo for a same-repo PR or an old cached intent.
      def head_repo(intent)
        intent.head_repo || intent.repo
      end
    end
  end
end
