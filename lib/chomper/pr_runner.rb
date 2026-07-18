require "json"
require "uri"
require "git"
require_relative "clients"
require_relative "pull"
require_relative "gh_pull"
require_relative "gh_pr_cache"

module Chomper
  # The terminal `pr` command: refresh one or more work packages' shipped PRs on
  # demand. For each open PR a WP shipped (one per <id>/repos/<name>/), it merges
  # the latest base branch into the PR branch (Claude resolves any conflicts),
  # fixes what CI is failing on, and addresses review feedback that arrived since
  # chomper last acted — then commits and pushes the result to the PR's head repo
  # after a terminal confirmation.
  #
  # This is gh-agent's own-PR machinery driven by the operator instead of a
  # polling trigger: no @chomper mention is needed, no allowlist applies (the
  # operator running the command is the authorization), and CI fixing works
  # regardless of CHOMPER_CI_FIX, act-state, or the attempt cap. The draft-PR +
  # human-gated-merge safety is unchanged — pushes go to the PR's head branch
  # only, and the terminal confirmation adds a gate gh-agent doesn't have.
  #
  # gh-agent reuses this via #refresh_one for an allowlisted "@chomper refresh"
  # PR comment, constructed with `interactive: false`: the push then follows
  # gh-agent's rules instead of the terminal prompt — fork-mode pushes go
  # straight to the bot's fork (a maintainer still gates the merge), direct-mode
  # pushes stay behind the interactive confirm_direct_push? gate.
  class PrRunner
    include Helpers
    include GhPrCache

    def initialize(ctx, claude: Claude.new(ctx), github: Clients::GitHub.new(ctx.github_token),
                   gh_pull: nil, op_pull: nil, interactive: true)
      @ctx         = ctx
      @claude      = claude
      @github      = github
      @interactive = interactive
      # Reused only for its act-state writers (comment cutoff + own-reply ids),
      # so gh-agent never re-handles feedback this command already addressed.
      @gh_pull = gh_pull || GhPull.new(ctx, github: github)
      # Mirrors the WP into the local cache before a refresh, as `pull` does.
      @op_pull = op_pull || Pull.new(ctx)
    end

    # Each target is a work-package id or a pasted GitHub PR URL (resolved to
    # its WP via chomper's own state, else via the OpenProject ticket link at
    # the top of the PR description). A WP id with no local PR state is looked
    # up on GitHub — an open PR by the bot carrying the WP's ticket link — and
    # adopted the same way.
    def run(*targets)
      raise FatalError, "GITHUB_TOKEN is not set — `pr` needs it to read and update PRs." unless @ctx.github_token
      targets.each do |target|
        target.match?(%r{\Ahttps?://}) ? refresh_url(target) : refresh_wp(target)
      end
    end

    # One PR, driven by gh-agent's "@chomper refresh" trigger. The commenter
    # explicitly asked for a refresh, so the base merge is forced — it happens
    # even when the quiet-day heuristic (fresh commits on the branch) would
    # skip it. Raises on failure so gh-agent's error path reports it on the PR.
    def refresh_one(wp_id, repo_name)
      dir = Helpers.item_dir(@ctx, wp_id) / "repos" / repo_name.to_s
      raise "no shipped PR recorded for #{wp_label(wp_id)} (#{repo_name})" unless Helpers.file_has_content?(dir / "pr_url.txt")
      mirror_wp(wp_id)
      refresh!(wp_id, dir, force_base_merge: true)
    end

    private

    def refresh_wp(wp_id)
      dirs = pr_dirs_for(wp_id)
      dirs = adopt_wp_prs(wp_id) if dirs.empty?
      if dirs.empty?
        log_script "#{wp_label(wp_id)} — no shipped PR found, locally or on GitHub. " \
                   "Ship one first with `./chomper ship #{wp_id}`."
        return
      end
      mirror_wp(wp_id)
      dirs.each { |dir| refresh(wp_id, dir) }
    end

    # A pasted PR URL: refresh the WP dir chomper already tracks for it, or —
    # for a PR chomper has no state for — adopt it via the OpenProject ticket
    # link at the top of the PR description, mirroring that WP first so the
    # refresh prompt has the usual issue context.
    def refresh_url(url)
      base_repo = Clients::GitHub.repo_from_url(url)
      number    = Clients::GitHub.pr_number_from_url(url)

      wp_id, dir = locate_tracked_pr(base_repo, number)
      if dir
        mirror_wp(wp_id)
        refresh(wp_id, dir)
        return
      end

      # Strict registry match — Registry#by_upstream falls back to the default
      # repo, which would silently adopt a foreign PR into the wrong worktree.
      repo = @ctx.repos.all.find { |r| r.upstream.casecmp?(base_repo) }
      unless repo
        log_script "#{url} — base repo #{base_repo} is not in repos.json; chomper has no clone to work in."
        return
      end

      pr = @github.pull_request(base_repo, number)
      ticket_id = op_ticket_id(pr.body)
      unless ticket_id
        log_script "#{url} — no #{op_link_host} work-package link found at the top of the PR " \
                   "description; cannot tell which WP it belongs to. Add one (e.g. " \
                   "\"Ticket: #{@ctx.op_url}/work_packages/<id>\") and re-run."
        return
      end

      item  = mirror_wp(ticket_id)
      wp_id = item ? item["id"].to_s : ticket_id   # the mirror's display id is canonical
      dir   = Helpers.item_dir(@ctx, wp_id) / "repos" / repo.name
      dir.mkpath
      (dir / "pr_url.txt").write(pr.html_url.to_s) unless Helpers.file_has_content?(dir / "pr_url.txt")
      log_script "Adopted #{base_repo}##{number} as #{wp_label(wp_id)} (#{repo.name})."
      refresh(wp_id, dir)
    end

    # A WP id chomper has no local PR state for (the state was reset, or the PR
    # was shipped from another machine) may still have a live PR. Discover it:
    # search each registry repo's upstream for open PRs authored by the bot
    # that mention the id, and adopt the one whose ticket link resolves to this
    # WP — the same rule as URL adoption. The author check is the trust
    # boundary: `pr` pushes to a PR's head branch, and that is only chomper's
    # to touch on the bot's own PRs. Returns the adopted dirs ([] if none).
    def adopt_wp_prs(wp_id)
      bot = (@github.login rescue nil).to_s
      return [] if bot.empty?
      @ctx.repos.all.filter_map do |repo|
        query = %(repo:#{repo.upstream} is:pr is:open author:#{bot} "#{wp_id}" in:body)
        # The search is an untrusted pre-filter; each hit is re-fetched and the
        # author, host repo, and ticket link verified on the live PR.
        pr = @github.search_prs(query).lazy
                    .map  { |ref| @github.pull_request(repo.upstream, ref.number) }
                    .find { |p| adoptable?(p, repo, wp_id, bot) }
        next unless pr
        dir = Helpers.item_dir(@ctx, wp_id) / "repos" / repo.name
        dir.mkpath
        (dir / "pr_url.txt").write(pr.html_url.to_s)
        log_script "Adopted #{repo.upstream}##{pr.number} as #{wp_label(wp_id)} (#{repo.name})."
        dir
      end
    end

    def adoptable?(pr, repo, wp_id, bot)
      pr.user&.login.to_s.casecmp?(bot) &&
        Clients::GitHub.repo_from_url(pr.html_url.to_s)&.casecmp?(repo.upstream) &&
        op_ticket_id(pr.body).to_s.casecmp?(wp_id.to_s)
    end

    # The (wp_id, dir) already tracking this PR, matched on parsed repo+number
    # so URL formatting differences (trailing paths, query strings) don't matter.
    def locate_tracked_pr(base_repo, number)
      root = Helpers.items_dir(@ctx)
      return nil unless root.exist?
      root.children.select(&:directory?).sort.each do |item_dir|
        pr_dirs_for(item_dir.basename.to_s).each do |dir|
          tracked = (dir / "pr_url.txt").read.strip
          next unless Clients::GitHub.repo_from_url(tracked)&.casecmp?(base_repo) &&
                      Clients::GitHub.pr_number_from_url(tracked) == number
          return [item_dir.basename.to_s, dir]
        end
      end
      nil
    end

    # Refresh the WP's local mirror (item.json) the same way `pull` does, so the
    # refresh prompt reads current issue context (fresh WP comments included).
    # Best-effort: an OpenProject hiccup must not block fixing a PR — the
    # refresh then runs on the cached copy (or none). Returns the item or nil.
    def mirror_wp(wp_id)
      item = @op_pull.fetch_single_item(wp_id)
      log_script "Could not mirror #{wp_label(wp_id)} from OpenProject — continuing with the cached copy." unless item
      item
    rescue => e
      log_script "Could not mirror #{wp_label(wp_id)} from OpenProject (#{e.message}) — continuing with the cached copy."
      nil
    end

    # How many leading description lines are scanned for the ticket link — the
    # convention puts it at the very top ("Ticket: <link>"), and matching the
    # whole body would pick up incidental WP references further down.
    OP_TICKET_SCAN_LINES = 15

    # The work-package id from an OpenProject work-package link at the top of a
    # PR description, or nil. Only links to the configured instance count: a WP
    # on another instance can't be mirrored with this token, and per-instance
    # state means its id would collide with a local one.
    def op_ticket_id(body)
      host = op_link_host
      return nil unless host
      head = body.to_s.lines.first(OP_TICKET_SCAN_LINES).join
      head[%r{https?://#{Regexp.escape(host)}(?::\d+)?/(?:\S*?/)?(?:work_packages|wp)/(\d+|[A-Z][A-Z0-9_]*-\d+)\b}, 1]
    end

    def op_link_host
      URI(@ctx.op_url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    # The <id>/repos/<name>/ dirs holding a shipped PR for this WP (mirrors
    # GhPull#shipped_pr_dirs, scoped to one WP).
    def pr_dirs_for(wp_id)
      repos_dir = Helpers.item_dir(@ctx, wp_id) / "repos"
      return [] unless repos_dir.exist?
      repos_dir.children.select(&:directory?).sort
               .select { |d| Helpers.file_has_content?(d / "pr_url.txt") }
    end

    # Refresh one PR, reporting (not raising) failures so a WP that shipped to
    # several repos still gets its other PRs refreshed.
    def refresh(wp_id, dir)
      refresh!(wp_id, dir)
    rescue => e
      log_script "#{wp_label(wp_id)} (#{dir.basename}) — refresh failed: #{e.message}"
    end

    def refresh!(wp_id, dir, force_base_merge: false)
      repo_name = dir.basename.to_s
      repo      = @ctx.repos[repo_name]
      unless repo
        log_script "#{wp_label(wp_id)} — repo #{repo_name.inspect} is not in repos.json; skipping its PR."
        return
      end

      pr_url    = (dir / "pr_url.txt").read.strip
      base_repo = Clients::GitHub.repo_from_url(pr_url)
      number    = Clients::GitHub.pr_number_from_url(pr_url)
      unless base_repo && number
        log_script "#{wp_label(wp_id)} (#{repo_name}) — unrecognised PR URL #{pr_url.inspect}; skipping."
        return
      end

      pr = @github.pull_request(base_repo, number)
      unless pr.state.to_s == "open"
        @gh_pull.mark_pr_done(wp_id, repo_name)   # spare gh-agent the dead poll too
        log_script "#{wp_label(wp_id)} (#{repo_name}) — PR ##{number} is #{pr.state}; nothing to refresh."
        return
      end
      # An open PR must be polled: lift a pr_done left by an earlier closure, so
      # a reopened PR resumes gh-agent watching via this command.
      @gh_pull.clear_pr_done(wp_id, repo_name)

      content   = fetch_pr_content(dir, base_repo, number, pr)
      branch    = content["head_ref"].to_s
      head_repo = content["head_repo"] || base_repo
      # The PR's actual base ref, not the registry default — authoritative even
      # for a WP that overrode its base (target_base.json).
      base_ref  = pr.base.ref.to_s
      log_script "Refreshing #{wp_label(wp_id)} (#{repo_name}) — PR ##{number}, base #{base_ref}"

      # Sync the worktree to the PR's current head (the branch lives on the head
      # repo — the bot's fork), exactly as gh-agent does before acting.
      @github.fetch_branch(head_repo, branch: branch, worktree_path: repo.worktree_host)
      checkout_pr_branch(repo, branch)
      wt            = worktree(repo)
      original_head = wt.revparse("HEAD")

      conflicts  = (force_base_merge || stale_pr?(wt)) ? merge_base(wt, repo, branch, base_ref) : []
      ci_ref     = ci_failure_ref(dir, base_repo, content["head_sha"].to_s)
      ci_expired = ci_ref == :ci_detail_expired
      ci_ref     = nil if ci_expired
      feedback   = fresh_feedback(dir, content)

      if conflicts.empty? && ci_ref.nil? && feedback.empty?
        if wt.revparse("HEAD") == original_head
          if ci_expired
            log_script "#{wp_label(wp_id)} (#{repo_name}) — already in sync with #{base_ref}, so there " \
                       "is nothing to push; re-run the failed checks from the GitHub UI instead."
          else
            log_script "#{wp_label(wp_id)} (#{repo_name}) — PR is already fresh; nothing to do."
          end
          return
        end
        # Only the clean base merge — no Claude pass needed.
        deliver(wp_id, dir, repo, branch, head_repo, base_repo, number, original_head,
                reply: nil, feedback: [])
        return
      end

      reply = refresh_with_claude(wp_id, dir, repo, base_repo, number, content, base_ref,
                                  ci: ci_ref, conflicts: conflicts, feedback: feedback)
      commit_refresh(wp_id, wt, repo, branch, base_ref, conflicts)
      deliver(wp_id, dir, repo, branch, head_repo, base_repo, number, original_head,
              reply: reply, feedback: feedback)
    end

    # Only PRs whose branch has been quiet for a day get the base branch merged
    # in — a branch with fresh commits does not need merge commits churned into
    # it. Judged on the head commit's date (the worktree is already synced to
    # the PR head here), NOT the PR's updated_at: comments and reviews bump
    # updated_at too, and a fresh comment must not block the merge. CI fixes
    # and comment handling still run regardless of age.
    PR_REFRESH_MIN_AGE = 24 * 60 * 60

    def stale_pr?(wt)
      committed_at = wt.log(1).execute.first&.date
      return true if committed_at.nil?   # unknown age — keep the old always-merge behaviour
      stale = Time.now - committed_at > PR_REFRESH_MIN_AGE
      log_script "PR has commits from the last day — skipping the base merge." unless stale
      stale
    rescue Git::Error
      true
    end

    # Merge origin/<base> into the PR branch when it is behind. Returns the list
    # of conflicted paths — [] for an up-to-date branch or a clean merge (which
    # commits itself). A conflicted merge is left in progress, its markers in the
    # worktree, for Claude to resolve; commit_refresh concludes it.
    def merge_base(wt, repo, branch, base_ref)
      fetch_base(wt, repo, base_ref)
      return [] if wt.log.between("HEAD", "origin/#{base_ref}").execute.none?
      Helpers.adopt_github_author!(@ctx)
      log_script "Merging origin/#{base_ref} into #{branch}…"
      wt.merge("origin/#{base_ref}", "Merge #{base_ref} into #{branch}")
      []
    rescue Git::Error
      files = conflicted_files(repo)
      raise if files.empty?   # not a conflict — a real git failure
      log_script "Merge stopped on #{files.length} conflicted file(s) — Claude will resolve them."
      files
    end

    # The paths currently in conflict in the worktree.
    def conflicted_files(repo)
      out = IO.popen(["git", "-C", repo.worktree_host.to_s, "diff", "--name-only", "--diff-filter=U"], &:read)
      out.to_s.split("\n").map(&:strip).reject(&:empty?)
    end

    # Conflicted files Claude failed to resolve — any still carrying a conflict
    # marker at line start. (The bare ======= middle marker is not checked: a
    # plain line of equals signs is legitimate in Markdown/RDoc.)
    def unresolved_conflicts(repo, files)
      files.select do |f|
        path = repo.worktree_host / f
        path.exist? && path.read.match?(/^(<{7} |>{7} )/)
      end
    end

    # The container path of ci.json when the PR head's CI has a completed
    # failure (detail freshly cached); :ci_detail_expired when it failed but
    # every summary/annotation/log has aged out of retention (nothing for Claude
    # to act on — the caller falls back to a base sync + push, which re-runs
    # CI); else nil. Unlike gh-agent's poller this ignores CHOMPER_CI_FIX,
    # act-state, and the attempt cap — the operator explicitly asked.
    def ci_failure_ref(dir, base_repo, head_sha)
      return nil if head_sha.empty?
      ignore = @ctx.ci_ignored_checks
      checks = @github.check_runs(base_repo, head_sha)
                      .reject { |c| ignore.include?(c.name.to_s.strip.downcase) }
      case ci_status(checks)
      when :failed
        if ci_detail_expired?(checks)
          log_script "CI failed on #{head_sha[0, 7]} but the failing run is past GitHub's ~1-month " \
                     "log retention — syncing from the base branch instead; a push re-runs CI."
          return :ci_detail_expired
        end
        fetch_ci_content(dir, base_repo, head_sha, checks, ignore: ignore)
        container_path(dir / "ci.json")
      when :pending
        log_script "CI is still running — refreshing without it (re-run `pr` once it finishes)."
        nil
      end
    end

    # GitHub retains a run's logs/annotations for about a month; past that the
    # failed check runs still list but their detail is gone, so a fix prompt
    # built from them would be pure guesswork (and fetching the detail wasted
    # API calls). Judged on the newest failed check's completed_at.
    CI_DETAIL_RETENTION = 30 * 24 * 60 * 60

    def ci_detail_expired?(checks)
      failed_at = checks.select { |c| ci_failed?(c) }.filter_map(&:completed_at).max
      return false unless failed_at
      failed_at = Time.parse(failed_at.to_s) unless failed_at.is_a?(Time)
      Time.now - failed_at > CI_DETAIL_RETENTION
    rescue ArgumentError
      false
    end

    # Comments made since chomper last acted on this PR, excluding chomper's own
    # (recorded reply ids plus anything authored by the bot login). Unlike
    # gh-agent there is no @chomper-mention or allowlist gate: the operator
    # running `pr` is the trigger, and the point is to sweep up review feedback
    # that never pinged chomper.
    def fresh_feedback(dir, content)
      state  = gh_state(dir)
      cutoff = state["last_acted_comment_at"]
      acted  = (state["chomper_comment_ids"] || []).map(&:to_s)
      bot    = (@github.login rescue nil).to_s
      (content["comments"] || [])
        .reject { |c| acted.include?(c["id"].to_s) }
        .reject { |c| !bot.empty? && c["author"] == bot }
        .select { |c| cutoff.nil? || c["created_at"].to_s > cutoff }
        .sort_by { |c| c["created_at"].to_s }
    end

    def refresh_with_claude(wp_id, dir, repo, base_repo, number, content, base_ref, ci:, conflicts:, feedback:)
      item_file = Helpers.item_dir(@ctx, wp_id) / "item.json"
      plan_file = Helpers.item_dir(@ctx, wp_id) / "plan.md"
      prompt = Prompts.pr_refresh(
        worktree: repo.worktree_container, repo: base_repo, pr_number: number,
        title: content["title"].to_s, base: base_ref,
        item: Helpers.file_has_content?(item_file) ? container_path(item_file) : "(no issue recorded)",
        plan: Helpers.file_has_content?(plan_file) ? container_path(plan_file) : "(no plan recorded)",
        pr_thread: container_path(dir / "pr.json"),
        ci: ci, conflicts: conflicts, feedback_count: feedback.length
      )
      # Shares gh-agent's per-PR session so prior PR conversations carry over.
      @claude.run(prompt, tools: Claude::TOOLS_IMPL, session_file: dir / "gh_session_id")
    end

    # Commit what the refresh produced. A conflicted merge is concluded here (the
    # merge commit carries the resolution — plus any CI/feedback fixes made in
    # the same pass); otherwise any files Claude changed become a follow-up
    # commit with a generated subject, exactly like gh-agent's comment fixes.
    # No-ops when Claude changed nothing (e.g. it only answered questions).
    def commit_refresh(wp_id, wt, repo, branch, base_ref, conflicts)
      Helpers.adopt_github_author!(@ctx)
      if conflicts.any?
        still = unresolved_conflicts(repo, conflicts)
        if still.any?
          wt.reset_hard("HEAD")   # abort the in-progress merge, leaving the worktree clean
          raise "conflicts left unresolved in #{still.join(", ")} — this merge needs a human"
        end
        wt.add(all: true)
        wt.commit("Merge #{base_ref} into #{branch}")
        log_script "Merge conflicts resolved and committed."
        record_progress(wp_id, branch, "refresh-merge:#{repo.name}")
      else
        wt.add(all: true)
        diff = wt.diff("HEAD")
        return if diff.entries.empty?
        diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        subject = generate_commit_subject(diff)
        label   = wp_label(wp_id)
        wt.commit(subject.empty? ? "[#{label}] refresh PR" : "[#{label}] #{subject}")
        c = wt.log(1).execute.first
        log_script "Committed: #{c.sha[0, 7]} #{c.message}"
        record_progress(wp_id, branch, "refresh-commit:#{repo.name}")
      end
    end

    # Push whatever the refresh produced (after a terminal confirmation), post
    # Claude's summary on the PR, and advance the comment cutoff over the
    # feedback just addressed so gh-agent doesn't act on it again. A discard
    # resets the branch and acknowledges nothing, so a re-run starts over.
    def deliver(wp_id, dir, repo, branch, head_repo, base_repo, number, original_head, reply:, feedback:)
      wt = worktree(repo)
      if wt.revparse("HEAD") == original_head
        log_script "#{wp_label(wp_id)} (#{repo.name}) — no code changes to push."
      elsif confirm_push?(wp_id, branch, head_repo)
        @github.push_branch(head_repo, branch: branch, worktree_path: repo.worktree_host)
        log_script "Pushed to #{head_repo} — PR ##{number} updated."
        record_progress(wp_id, branch, "refreshed:#{repo.name}")
      else
        wt.reset_hard(original_head)
        log_script "#{wp_label(wp_id)} (#{repo.name}) — discarded; branch reset to the PR head."
        return
      end

      post_summary(wp_id, dir, base_repo, number, reply)
      latest = feedback.map { |c| c["created_at"].to_s }.max
      @gh_pull.mark_acted(wp_id, repo.name, latest) if latest
    end

    def confirm_push?(wp_id, branch, head_repo)
      # A gh-agent-triggered refresh follows gh-agent's push rules: a fork-mode
      # push passes straight through (the branch only touches the bot's fork),
      # a direct-mode one stays behind the interactive confirm_direct_push? gate.
      return confirm_direct_push?(head_repo, branch) unless @interactive
      # AUTO_PLAN_APPROVAL never bypasses the gate in direct mode — there the
      # push lands on the canonical repo, and every such push stays interactive.
      return true if @ctx.auto_plan_approval? && !@ctx.direct_pr?
      ping_terminal("chomper: refreshed #{wp_label(wp_id)} — ready to push")
      loop do
        print "  [y]es push #{branch} / [d]iscard: "
        response = $stdin.gets&.chomp&.downcase || ""
        case response
        when "", "y", "yes" then return true
        when "d", "discard" then return false
        else puts "  Please enter y or d."
        end
      end
    end

    # Post Claude's summary as a PR comment (labelled automated, like gh-agent's
    # replies) and record its id so the pollers never treat it as a trigger.
    def post_summary(wp_id, dir, base_repo, number, reply)
      text = reply.to_s.strip
      return if text.empty?
      comment = @github.add_issue_comment(base_repo, number, "🤖 #{text}")
      @gh_pull.record_chomper_comment(wp_id, dir.basename.to_s, comment&.id)
    rescue => e
      log_script "Reply failed on #{base_repo}##{number}: #{e.message}"
    end
  end
end
