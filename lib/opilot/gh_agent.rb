require "json"
require_relative "clients"
require_relative "gh_pull"
require_relative "upstream_gh_pull"
require_relative "pr_runner"

module OPilot
  # The GitHub counterpart of Agent. Two sources, polled together every tick:
  # 1. opilot's own PRs (GhPull) — "always reply, code if asked": the LLM edits
  #    the worktree when a comment asks, and the change is committed and pushed to
  #    the bot's fork to update the draft PR.
  # 2. upstream PRs that @-mention opilot (UpstreamGhPull) — opilot has no write
  #    access to these branches, so those intents are `reply_only`: it reviews and
  #    answers in text but never pushes code.
  # Either way merging stays gated on a maintainer, so a person is always in the
  # loop on anything that lands.
  class GhAgent
    include Helpers

    # gh-agent acts exclusively as the CONTRIBUTOR bot: it watches the bot's
    # own PRs and pushes only to the bot's fork.
    def initialize(ctx, pull: GhPull.new(ctx), upstream_pull: UpstreamGhPull.new(ctx),
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

    # Prompt for the scan window and print the allowlist banner. Returned value
    # is passed to #tick. Split out from #run so CombinedAgent can drive the loop.
    def setup
      scan_from_at = prompt_scan_from
      if @ctx.allowed_gh_users.any?
        puts "  Allowlist active — only @opilot from: #{@ctx.allowed_gh_users.map { |u| "@#{u}" }.join(", ")}"
      else
        puts "  No allowlist set (OPILOT_ALLOWED_GH_USERS) — any GitHub user can trigger @opilot on opilot's own PRs."
      end
      # Say which state we are in either way: "it scanned nothing" and "it isn't
      # scanning" look identical in the log otherwise.
      if @upstream_pull.enabled?
        puts "  Tracking upstream PRs for @opilot mentions — #{@ctx.repos.all.map(&:upstream).join(", ")}."
      elsif @ctx.track_upstream_prs?
        puts "  Upstream PR tracking requested but OFF — it also needs OPILOT_ALLOWED_GH_USERS."
      else
        puts "  Upstream PR tracking off — opilot's own PRs only (set OPILOT_TRACK_UPSTREAM_PRS=1)."
      end
      scan_from_at
    end

    # Which PR sources this run watches — upstream is opt-in, so don't claim it.
    def sources
      @upstream_pull.enabled? ? "opilot + upstream PRs" : "opilot's own PRs"
    end

    # One poll-and-handle pass over the active PR sources (no sleep).
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

    # Handle one comment, then mark it acted. As in Agent#handle_and_ack, a
    # *handled* error is reported on the PR and still acked (no replay); only an
    # uncaught crash or a Ctrl-C (SystemExit passes this rescue) leaves the
    # comment for the next poll — an interrupt must not leak an error onto a
    # public PR or ack the comment unhandled.
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

    # An upstream PR opilot did not open: fetch its head read-only so the LLM can
    # read the diff, then review/answer in text. Never commits or pushes.
    def handle_review(intent)
      repo         = @ctx.repos.by_upstream(intent.repo)
      dir          = @upstream_pull.pr_dir(intent.repo, intent.pr_number)
      pr_file      = dir / "pr.json"
      ci_file      = dir / "ci.json"
      session_file = dir / "gh_session_id"

      @github.fetch_branch(head_repo(intent), branch: intent.branch, worktree_path: repo.worktree_host)
      checkout_pr_branch(repo, intent.branch)

      prompt = Prompts.pr_review(
        repo: intent.repo, pr_number: intent.pr_number, title: intent.subject,
        worktree: repo.worktree_container, base: repo.base, pr_thread: container_path(pr_file),
        comment: intent.text.to_s, author: intent.user_login.to_s,
        comment_id: intent.comment_id, in_reply_to: intent.in_reply_to,
        ci: review_ci_ref(ci_file, intent.head_sha)
      )
      reply = @harness.run(prompt, tools: Harness::TOOLS_READ, session_file: session_file)
      post_suggestions(intent, reply)
      post_reply(intent, reply)
    end

    # Post any GitHub suggestions the review proposed as an applicable inline
    # review, so the author can commit opilot's edits with one click — opilot
    # can't push to a PR it doesn't own. Best-effort: a bad line range 422s the
    # whole review, so a failure just logs and the prose reply still carries the
    # details. Needs the head SHA to anchor the comments to the diff opilot read.
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

    # Parse the optional SUGGESTIONS block (before the REPLY line) into GitHub
    # review-comment hashes carrying ```suggestion bodies. Best-effort: malformed
    # or absent JSON yields none and only the prose reply is posted.
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

    # The container path to the upstream PR's cached CI-failure detail, or nil.
    # UpstreamGhPull writes ci.json only when CI is failing; guard on the head
    # SHA so a stale failure cached against an earlier commit isn't shown as
    # current after a new push.
    def review_ci_ref(ci_file, head_sha)
      return nil if head_sha.to_s.empty?
      data = Helpers.safe_json_read(ci_file)
      return nil unless data && data["head_sha"].to_s == head_sha.to_s
      container_path(ci_file)
    end

    def handle_own(intent)
      repo         = @ctx.repos.by_upstream(intent.repo)
      item_dir     = Helpers.item_dir(@ctx, intent.item_id)
      pr_dir       = item_dir / "repos" / intent.repo_name
      item_file    = item_dir / "item.json"
      plan_file    = item_dir / "plan.md"
      pr_file      = pr_dir / "pr.json"
      session_file = pr_dir / "gh_session_id"

      # Fetch the PR head over HTTPS (never the worktree's possibly-SSH origin),
      # then sync the branch to it before the LLM touches anything. The branch
      # lives in the PR's head repo — the user's fork — not the base repo.
      @github.fetch_branch(head_repo(intent), branch: intent.branch, worktree_path: repo.worktree_host)
      checkout_pr_branch(repo, intent.branch)

      plan_ref = Helpers.file_has_content?(plan_file) ? container_path(plan_file) : "(no plan recorded)"
      prompt = Prompts.gh_reply(
        worktree: repo.worktree_container, repo: intent.repo, pr_number: intent.pr_number,
        title: intent.subject, item: container_path(item_file), plan: plan_ref,
        pr_thread: container_path(pr_file), comment: intent.text.to_s,
        author: intent.user_login.to_s, comment_id: intent.comment_id, in_reply_to: intent.in_reply_to
      )
      reply = @harness.run(prompt, tools: Harness::TOOLS_IMPL, session_file: session_file)

      post_reply(intent, reply)
      push_followup(intent, repo) if commit_followup(intent, repo)
    end

    # CI failed on one of opilot's own PRs. Same shape
    # as handle_own — sync the PR head, let the LLM read the cached failure detail
    # (ci.json: failed checks, annotations, failed-job log tails) and fix it in
    # the worktree, then commit + push to update the draft PR. the LLM may make no
    # change (e.g. a flaky/infra failure it shouldn't "fix"), in which case it
    # just replies and nothing is pushed.
    def handle_ci(intent)
      repo         = @ctx.repos.by_upstream(intent.repo)
      item_dir     = Helpers.item_dir(@ctx, intent.item_id)
      pr_dir       = item_dir / "repos" / intent.repo_name
      item_file    = item_dir / "item.json"
      plan_file    = item_dir / "plan.md"
      pr_file      = pr_dir / "pr.json"
      ci_file      = pr_dir / "ci.json"
      session_file = pr_dir / "gh_session_id"

      @github.fetch_branch(head_repo(intent), branch: intent.branch, worktree_path: repo.worktree_host)
      checkout_pr_branch(repo, intent.branch)

      plan_ref = Helpers.file_has_content?(plan_file) ? container_path(plan_file) : "(no plan recorded)"
      item_ref = Helpers.file_has_content?(item_file) ? container_path(item_file) : "(no issue recorded)"
      prompt = Prompts.fix_ci(
        worktree: repo.worktree_container, repo: intent.repo, pr_number: intent.pr_number,
        title: intent.subject, item: item_ref, plan: plan_ref,
        pr_thread: container_path(pr_file), ci: container_path(ci_file)
      )
      reply = @harness.run(prompt, tools: Harness::TOOLS_IMPL, session_file: session_file)

      post_reply(intent, reply)
      push_followup(intent, repo) if commit_followup(intent, repo)
    end

    # "@opilot refresh" on one of opilot's own PRs: hand it to PrRunner for
    # the full `pr`-command treatment — a forced base-branch merge (the trigger
    # comment just bumped updated_at, so the quiet-day heuristic would always
    # skip it), a CI fix regardless of act-state/attempt cap, and
    # a sweep of fresh feedback (the trigger comment included, so the commenter
    # gets a reply). PrRunner posts its own summary and advances the comment
    # cutoff; handle_and_ack then acks the trigger comment as usual.
    def handle_refresh(intent)
      pr_runner.refresh_one(intent.item_id, intent.repo_name)
    end

    # A comment on a `pd` change proposal's PR. `pd propose` is first-shot only,
    # so this is where a proposal actually gets iterated: the LLM revises the spec
    # artifacts, the runner re-validates and re-checks the write scope, and the
    # revision is pushed to update the PR.
    #
    # The branch lives on the bot's own fork (head and base both there), so the
    # push needs no confirmation and reaches no canonical repo.
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

    # Did revise_proposal leave a commit to push? It commits internally (the spec
    # tree is git-excluded, so it needs a deliberate force-add), unlike the
    # code path where commit_followup does it here.
    def spec_commit_pending?(repo, branch)
      worktree(repo).log.between("FETCH_HEAD", branch).execute.any?
    rescue StandardError
      false
    end

    private

    # Built lazily and without a PD::Intake: revising a proposal never reads a
    # document, and Intake would drag roo/nokogiri into every gh-agent run.
    def product_runner
      @product_runner ||= begin
        require_relative "pd"
        PD::Runner.new(@ctx, harness: @harness)
      end
    end

    # Built lazily: PrRunner's default OpenProject client (for the WP mirror)
    # is only needed once a refresh is actually triggered.
    def pr_runner
      @pr_runner ||= PrRunner.new(@ctx, harness: @harness, github: @github,
                                  gh_pull: @pull, interactive: false)
    end

    def prompt_scan_from
      previous = saved_scan_from_at
      puts "  How far back should the PR comment scanner look?"
      puts "  Formats: \"2h\", \"3 days\", \"1 week\", \"1 month\""
      print "  Scan from [#{previous || "now"}]: "
      reply = $stdin.gets.to_s.chomp
      scan_from_at = (previous && reply.strip.empty?) ? previous : Helpers.parse_scan_from(reply)
      save_scan_from_at(scan_from_at)
      scan_from_at
    end

    # Persist the chosen scan floor so the next run can offer it as the default,
    # letting gh-agent resume from where it left off instead of skipping to now.
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

    # Post the LLM's reply: in-thread for an inline review comment, otherwise on
    # the PR's conversation. Records our comment id so it isn't re-triggered.
    def post_reply(intent, body)
      text = Helpers.extract_reply(body)
      return if text.empty?
      # Label every reply as automated so readers don't mistake it for a human
      # comment posted under the token owner's identity.
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

    # Route act-state to the source the intent came from: opilot's own PRs are
    # keyed by WP item + repo name; upstream PRs by repo + number.
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

    # Commit whatever the LLM changed in the worktree. Returns true when a commit
    # was made, false when the comment was answered without touching any file.
    def commit_followup(intent, repo)
      Helpers.adopt_github_author!(@ctx.contributor_token)
      wt = worktree(repo)
      wt.add(all: true)
      diff = wt.diff("HEAD")
      return false if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      wt.commit(feedback_commit_message(intent, diff))
      c = wt.log(1).execute.first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"
      record_progress(intent.item_id, intent.branch, "gh-commit")
      true
    end

    # The subject for a follow-up commit: the WP label (matching the PR title's
    # "[label] …" form) plus a concise description of the change the LLM just made
    # (Helpers#generate_commit_subject). Falls back to a generic subject when
    # subject generation yields nothing.
    def feedback_commit_message(intent, diff)
      label   = wp_label(intent.item_id)
      subject = generate_commit_subject(diff)
      subject.empty? ? "[#{label}] address PR feedback" : "[#{label}] #{subject}"
    end

    # Push the new commit to the PR's head repo with the bot token, updating the
    # draft PR. For the bot's own PRs there is no confirmation: the branch lives
    # on the bot's fork and a maintainer still gates the merge, so nothing
    # reaches the canonical repo without human review. A head that IS a
    # canonical repo (e.g. a PR a maintainer adopted and re-published) is
    # refused — and the bot token couldn't push there anyway.
    def push_followup(intent, repo)
      target = head_repo(intent)
      if refuse_canonical_push?(target, intent.branch)
        log_script "PR ##{intent.pr_number} not updated (the commit stays in the clone)."
        return
      end
      @github.push_branch(target, branch: intent.branch, worktree_path: repo.worktree_host)
      log_script "Pushed to #{target} — PR ##{intent.pr_number} updated."
    end

    # The repo holding the PR's branch — the fork. Falls back to the base repo
    # for a same-repo PR or a cached intent from before head_repo was tracked.
    def head_repo(intent)
      intent.head_repo || intent.repo
    end
  end
end
