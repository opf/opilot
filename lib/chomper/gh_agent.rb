require "json"
require_relative "clients"
require_relative "gh_pull"

module Chomper
  # The GitHub counterpart of Agent: poll the PRs chomper has already opened for
  # @chomper comments and act on each. "Always reply, code if asked" — every
  # comment gets a reply, and Claude edits the worktree only when the comment
  # asks for a change. A code change is committed and pushed to the bot's fork to
  # update the draft PR; merging into the canonical repo still needs a maintainer,
  # so a person stays in the loop on anything that actually lands.
  class GhAgent
    include Helpers

    def initialize(ctx, pull: GhPull.new(ctx), claude: Claude.new(ctx),
                   github: Clients::GitHub.new(ctx.github_token))
      @ctx    = ctx
      @pull   = pull
      @claude = claude
      @github = github
    end

    def run
      unless @ctx.github_token
        puts "  Error: GITHUB_TOKEN is not set — gh-agent needs it to read and comment on PRs."
        return
      end
      scan_from_at = setup
      puts "  gh-agent started — polling chomper PRs every 10s. Ctrl-C to stop."

      until Chomper.stopping?
        tick(scan_from_at)
        sleep 10 unless Chomper.stopping?
      end
      puts "  Stopped."
    end

    # Prompt for the scan window and print the allowlist banner. Returned value
    # is passed to #tick. Split out from #run so CombinedAgent can drive the loop.
    def setup
      scan_from_at = prompt_scan_from
      if @ctx.allowed_gh_users.any?
        puts "  Allowlist active — only @chomper from: #{@ctx.allowed_gh_users.map { |u| "@#{u}" }.join(", ")}"
      else
        puts "  No allowlist set (CHOMPER_ALLOWED_GH_USERS) — any GitHub user can trigger @chomper."
      end
      scan_from_at
    end

    # One poll-and-handle pass over chomper's open PRs (no sleep).
    def tick(scan_from_at)
      intents = @pull.poll_intents(scan_from_at)
      n = intents.length
      log_script "Polled #{@pull.scanned_count} chomper PR(s) — " \
                 "#{n} @chomper trigger#{n == 1 ? "" : "s"}"
      intents.each do |intent|
        break if Chomper.stopping?
        handle_and_ack(intent)
      end
    end

    # Handle one comment, then mark it acted. As in Agent#handle_and_ack, a
    # *handled* error is reported on the PR and still acked (no replay); only an
    # uncaught crash leaves the comment for the next poll.
    def handle_and_ack(intent)
      handle(intent)
    rescue => e
      log_script "Error on #{intent.repo}##{intent.pr_number}: #{e.message}"
      post_reply(intent, "sorry — I hit an error handling that comment:\n\n#{e.message}") rescue nil
    ensure
      @pull.mark_acted(intent.item_id, intent.comment_at)
    end

    def handle(intent)
      log_script "#{intent.repo}##{intent.pr_number} — @#{intent.user_login} (#{intent.kind} comment)"
      dir          = Helpers.item_dir(@ctx, intent.item_id)
      item_file    = dir / "item.json"
      plan_file    = dir / "plan.md"
      pr_file      = dir / "pr.json"
      session_file = dir / "gh_session_id"

      # Fetch the PR head over HTTPS (never the worktree's possibly-SSH origin),
      # then sync the branch to it before Claude touches anything. The branch
      # lives in the PR's head repo — the user's fork — not the base repo.
      @github.fetch_branch(head_repo(intent), branch: intent.branch, worktree_path: @ctx.worktree_host)
      checkout_pr_branch(intent.branch)

      plan_ref = Helpers.file_has_content?(plan_file) ? container_path(plan_file) : "(no plan recorded)"
      prompt = Prompts.gh_reply(
        worktree: @ctx.worktree_container, repo: intent.repo, pr_number: intent.pr_number,
        title: intent.subject, item: container_path(item_file), plan: plan_ref,
        pr_thread: container_path(pr_file), comment: intent.text.to_s,
        author: intent.user_login.to_s, comment_id: intent.comment_id, in_reply_to: intent.in_reply_to
      )
      reply = @claude.run(prompt, tools: Claude::TOOLS_IMPL, session_file: session_file)

      post_reply(intent, reply)
      push_followup(intent) if commit_followup(intent, session_file)
    end

    private

    def prompt_scan_from
      puts "  How far back should the PR comment scanner look?"
      puts "  Formats: \"1h\", \"2 days\", \"1 week\""
      print "  Scan from [now]: "
      Helpers.parse_scan_from($stdin.gets.to_s.chomp)
    end

    # Post Claude's reply: in-thread for an inline review comment, otherwise on
    # the PR's conversation. Records our comment id so it isn't re-triggered.
    def post_reply(intent, body)
      text = body.to_s.strip
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
      @pull.record_chomper_comment(intent.item_id, comment&.id)
    rescue => e
      log_script "Reply failed on #{intent.repo}##{intent.pr_number}: #{e.message}"
    end

    # Commit whatever Claude changed in the worktree. Returns true when a commit
    # was made, false when the comment was answered without touching any file.
    def commit_followup(intent, session_file)
      Helpers.adopt_github_author!(@ctx)
      worktree.add(all: true)
      diff = worktree.diff("HEAD")
      return false if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      worktree.commit(feedback_commit_message(intent, session_file))
      c = worktree.log(1).execute.first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"
      record_progress(intent.item_id, intent.branch, "gh-commit")
      true
    end

    # The subject for a follow-up commit: the WP label (matching the PR title's
    # "[label] …" form) plus a concise description of the change Claude just made.
    # Falls back to a generic subject when subject generation yields nothing.
    def feedback_commit_message(intent, session_file)
      label   = wp_label(intent.item_id)
      subject = generate_commit_subject(session_file)
      subject.empty? ? "[#{label}] address PR feedback" : "[#{label}] #{subject}"
    end

    # Ask Claude — in the same session that just made the change, so the diff is
    # already in context — for a one-line commit subject, then sanitise it to a
    # single bare line. Returns "" on any failure so the caller can fall back.
    def generate_commit_subject(session_file)
      reply = @claude.run(Prompts.commit_subject, tools: Claude::TOOLS_READ, session_file: session_file)
      strip_ansi(reply.to_s).lines.map(&:strip).find { |l| !l.empty? }.to_s
        .gsub(/\A["'`]+|["'`]+\z/, "")   # strip wrapping quotes/backticks
        .sub(/\A\[[^\]]*\]\s*/, "")       # drop any "[label]" Claude prepended anyway
        .gsub(/\s+/, " ")
        .slice(0, 72).to_s.strip
    rescue => e
      log_script "Commit-subject generation failed: #{e.message}"
      ""
    end

    # Push the new commit to the PR's head repo (the bot's fork) with the bot
    # token, updating the draft PR. No confirmation: it's a draft PR on the bot's
    # fork and a maintainer still gates the merge, so nothing reaches the
    # canonical repo without human review.
    def push_followup(intent)
      target = head_repo(intent)
      @github.push_branch(target, branch: intent.branch, worktree_path: @ctx.worktree_host)
      log_script "Pushed to #{target} — PR ##{intent.pr_number} updated."
    end

    # The repo holding the PR's branch — the fork. Falls back to the base repo
    # for a same-repo PR or a cached intent from before head_repo was tracked.
    def head_repo(intent)
      intent.head_repo || intent.repo
    end
  end
end
