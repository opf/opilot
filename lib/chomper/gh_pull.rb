require "json"
require "time"
require_relative "clients"
require_relative "gh_pr_cache"

module Chomper
  # A comment on a chomper PR that mentions @chomper, normalised so GhAgent can
  # act on it. `kind` is :issue (the PR conversation thread) or :review (inline
  # on a diff line); review comments carry `comment_id`, and `in_reply_to` points
  # at the parent comment when the trigger is a reply in a review thread (e.g. you
  # answering a Copilot finding) so Claude can be pointed at the right feedback.
  # `repo` is the base repo the PR targets (where comments are posted); `head_repo`
  # is where the PR's branch actually lives (the user's fork) — what gh-agent
  # fetches from and pushes to. `reply_only` is true for an upstream PR chomper did
  # NOT open (it can review/answer but cannot push code there).
  #
  # `kind` is also :ci for a CI-failure trigger (gh-agent's auto-fix path on
  # chomper's own PRs): there is no comment, so `text`/`comment_id` are nil and
  # `head_sha` carries the commit whose checks failed — the key the act-state is
  # deduped on, since CI isn't comment-timestamp driven.
  #
  # `command` is :refresh when the comment is "@chomper refresh" on one of
  # chomper's own PRs — the full `pr`-command treatment (base merge + CI fix +
  # feedback sweep) instead of a conversational reply. Nil for everything else;
  # never set on a reply_only intent (chomper can't push to an upstream branch).
  # `spec_change_id` is set when the PR is a `pd` change proposal living in the
  # bot's own fork: `item_id` is then the change id rather than a work-package
  # id, and the act-state lives under changes/<host>/<change-id>/ rather than
  # work_packages/. gh-agent routes those to the proposal-revision path.
  GhIntent = Struct.new(:item_id, :repo_name, :subject, :branch, :repo, :head_repo, :pr_number, :pr_url,
                        :kind, :command, :comment_id, :in_reply_to, :text, :user_login, :comment_at,
                        :reply_only, :head_sha, :spec_change_id,
                        keyword_init: true) do
    def spec?
      !spec_change_id.nil?
    end
  end

  # The GitHub counterpart of Pull: scans the PRs chomper has already opened (one
  # per work_packages/<host>/<id>/repos/<name>/pr_url.txt) for new @chomper comments.
  #
  # Two files per PR, mirroring how Pull splits a WP's cache from its act-state:
  # - pr.json    — the cached PR content (metadata + every comment and review,
  #                including reviewer feedback like Copilot's), keyed by the PR's
  #                updated_at, exactly as item.json is keyed by the WP's updatedAt.
  # - gh_pr.json — gh-agent's act-state: `last_acted_comment_at` (replay cutoff)
  #                and `chomper_comment_ids` (our own replies). Kept separate so
  #                it isn't rewritten on every content refresh and so pr.json can
  #                be handed to Claude without leaking bookkeeping.
  class GhPull
    include Helpers
    include GhPrCache

    def initialize(ctx, github: Clients::GitHub.new(ctx.contributor_token))
      @ctx    = ctx
      @github = github
    end

    attr_reader :scanned_count

    # The per-repo PR dirs gh-agent watches: <id>/repos/<name>/ holding a
    # shipped PR. A WP that shipped to several repos yields several dirs, each an
    # independent PR with its own cache, act-state, and session.
    def shipped_pr_dirs
      root = Helpers.items_dir(@ctx)
      return [] unless root.exist?
      root.children.select(&:directory?).sort.flat_map do |item_dir|
        repos_dir = item_dir / "repos"
        next [] unless repos_dir.exist?
        repos_dir.children.select(&:directory?).sort
                 .select { |d| Helpers.file_has_content?(d / "pr_url.txt") }
      end
    end

    # Poll every watched PR and return the new @chomper comments as GhIntents,
    # oldest first so a review's several inline comments are each handled in turn.
    # `scan_from_at` (ISO8601) is the floor cutoff entered at startup.
    # The per-change dirs holding a `pd` spec PR. Same cache/act-state shape as a
    # shipped PR dir, in the change namespace instead of the work-package one —
    # a proposal is keyed by change id and has no work package until it is
    # published.
    def spec_pr_dirs
      root = Helpers.changes_dir(@ctx)
      return [] unless root.exist?
      root.children.select(&:directory?).sort
          .select { |d| Helpers.file_has_content?(d / "pr_url.txt") }
    end

    def poll_intents(scan_from_at)
      @scan_from_at = scan_from_at
      # A dir whose PR was already seen merged/closed (pr_done, set below when
      # the closure is first observed) costs nothing — not even the metadata
      # call. `./chomper wp pr <url>` clears the flag if the PR is ever reopened.
      shipped = shipped_pr_dirs.reject { |d| gh_state(d)["pr_done"] }
      specs   = spec_pr_dirs.reject { |d| gh_state(d)["pr_done"] }
      @scanned_count = shipped.length + specs.length

      intents = []
      shipped.each { |d| intents.concat(intents_for_dir(d)) }
      specs.each   { |d| intents.concat(intents_for_dir(d, spec: true)) }
      intents
    end

    # Where an intent's cache and act-state live: <id>/repos/<name>/ for a
    # shipped PR, changes/<change-id>/ for a spec PR.
    def pr_dir(item_id, repo_name, spec: false)
      return Helpers.change_dir(@ctx, item_id) if spec
      Helpers.item_dir(@ctx, item_id) / "repos" / repo_name.to_s
    end

    # Advance a PR's replay cutoff past a comment we've acted on (mirrors
    # Pull#mark_acted). Keyed by item id + repo so each PR tracks its own state.
    def mark_acted(item_id, repo_name, comment_at, spec: false)
      dir   = pr_dir(item_id, repo_name, spec: spec)
      state = gh_state(dir)
      state["last_acted_comment_at"] = [state["last_acted_comment_at"], comment_at].compact.max
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Remember a reply chomper posted so its own comment is never re-detected as
    # a trigger (mirrors Pull#record_chomper_comment). Capped so the list can't
    # grow without bound on a long-lived PR.
    def record_chomper_comment(item_id, repo_name, comment_id, spec: false)
      return unless comment_id
      dir   = pr_dir(item_id, repo_name, spec: spec)
      state = gh_state(dir)
      ids   = (state["chomper_comment_ids"] || []).map(&:to_s)
      ids << comment_id.to_s unless ids.include?(comment_id.to_s)
      state["chomper_comment_ids"] = ids.last(200)
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Record that this dir's PR has been seen merged/closed, so the poller stops
    # spending an API call on it every tick (a long-dead PR would otherwise be
    # re-fetched forever). Merged is irreversible; a closed PR *can* be reopened,
    # which is what clear_pr_done (driven by the `pr` command) is for.
    def mark_pr_done(item_id, repo_name, spec: false)
      dir   = pr_dir(item_id, repo_name, spec: spec)
      state = gh_state(dir)
      state["pr_done"] = true
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Resume polling a PR that turned out to be open again (reopened after a
    # close). No-op when the flag isn't set, so routine refreshes don't churn
    # the state file.
    def clear_pr_done(item_id, repo_name)
      dir   = pr_dir(item_id, repo_name)
      state = gh_state(dir)
      return unless state.delete("pr_done")
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Record that chomper has addressed a head SHA's CI failure. Unlike comment
    # acks (timestamp cutoff), CI dedup is per-SHA: `ci_acted_sha` blocks acting
    # twice on the same commit, and `ci_attempts` caps how many times chomper
    # will chase a PR's CI before giving up.
    def mark_ci_acted(item_id, repo_name, head_sha)
      dir   = pr_dir(item_id, repo_name)
      state = gh_state(dir)
      state["ci_acted_sha"] = head_sha
      state["ci_attempts"]  = (state["ci_attempts"] || 0) + 1
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    private

    # `dir` is <id>/repos/<name>/ for a shipped PR — the repo subdir holds the PR
    # url, cache, and act-state, with item.json/plan.md one level up at the WP
    # root — or changes/<change-id>/ for a `pd` spec PR, which is flat and has no
    # work-package mirror beside it.
    def intents_for_dir(dir, spec: false)
      item_id, repo_name = spec ? spec_identity(dir) : [dir.parent.parent.basename.to_s, dir.basename.to_s]
      pr_url = (dir / "pr_url.txt").read.strip
      repo   = Clients::GitHub.repo_from_url(pr_url)
      number = Clients::GitHub.pr_number_from_url(pr_url)
      return [] unless repo && number

      pr = @github.pull_request(repo, number)
      # Don't touch PRs that are merged or closed — and remember the closure so
      # this dir never costs another poll (see poll_intents).
      unless pr.state.to_s == "open"
        mark_pr_done(item_id, repo_name, spec: spec)
        log_script "gh-agent: #{repo}##{number} is #{pr.state} — dropping it from future polls."
        return []
      end

      content = fetch_pr_content(dir, repo, number, pr)
      subject = default_subject(dir, content, spec: spec)

      state  = gh_state(dir)
      cutoff = [state["last_acted_comment_at"], @scan_from_at].compact.max
      acted  = (state["chomper_comment_ids"] || []).map(&:to_s)

      intents = fresh_mentions(content["comments"], cutoff, acted).filter_map do |c|
        # Off-allowlist comments still advance the cutoff so we don't re-evaluate
        # them every poll (mirrors Pull#intent_from_comments).
        unless allowed?(c["author"], pr_url)
          mark_acted(item_id, repo_name, c["created_at"], spec: spec)
          next nil
        end
        # 👀 the trigger comment so the commenter sees it's being worked on,
        # mirroring the OpenProject agent's react_eyes.
        @github.react(repo, c["id"], kind: c["kind"].to_sym)
        GhIntent.new(
          item_id: item_id, repo_name: repo_name, subject: subject, branch: content["head_ref"], repo: repo,
          head_repo: content["head_repo"], pr_number: number, pr_url: pr_url,
          kind: c["kind"].to_sym, command: (parse_command(c["body"]) unless spec),
          comment_id: c["id"], in_reply_to: c["in_reply_to"],
          text: c["body"], user_login: c["author"], comment_at: c["created_at"],
          spec_change_id: (item_id if spec)
        )
      end

      # Also react to a failed CI run — but not in the same tick as a comment
      # trigger for this PR: let the requested change land first, since CI
      # re-runs on the new commit anyway. Spec PRs are exempt: the diff is
      # markdown, so any CI on that branch is about code the change hasn't
      # touched and chasing it would burn attempts on something unfixable here.
      if intents.empty? && !spec
        ci = ci_intent_for_dir(dir, repo, number, pr_url, content, item_id, repo_name, subject)
        intents << ci if ci
      end
      intents
    rescue => e
      # One unreachable/renamed PR shouldn't stop the others being polled.
      log_script "gh-agent: skipping #{dir.basename} — #{e.message}"
      []
    end

    # A CI-failure intent for this PR, or nil when there's nothing to do: the
    # current head SHA was already addressed or already found green, the attempt
    # cap is spent (a one-time "needs a human" notice is posted then), or CI
    # hasn't finished. Only a completed run with ≥1 failed check produces an
    # intent — and ci.json is populated (annotations + failed-job logs) first.
    def ci_intent_for_dir(dir, repo, number, pr_url, content, item_id, repo_name, subject)
      head_sha = content["head_sha"].to_s
      return nil if head_sha.empty?

      # CI results are immutable per commit, so a SHA we've already chased or
      # already found green never needs another check-runs call — this is what
      # keeps a long-lived green PR from costing a request on every poll.
      state = gh_state(dir)
      return nil if [state["ci_acted_sha"], state["ci_quiet_sha"]].include?(head_sha)
      if (state["ci_attempts"] || 0) >= @ctx.ci_max_attempts
        announce_ci_give_up(dir, repo, number, state)
        return nil
      end

      # Drop checks chomper can't fix (e.g. "SaaS tests" — needs fork-inaccessible
      # secrets, so it always fails) before reading status, so they never trigger
      # a fix or burn an attempt.
      ignore     = @ctx.ci_ignored_checks
      check_runs = @github.check_runs(repo, head_sha)
                          .reject { |c| ignore.include?(c.name.to_s.strip.downcase) }
      case ci_status(check_runs)
      when :failed
        fetch_ci_content(dir, repo, head_sha, check_runs, ignore: ignore)
        GhIntent.new(
          item_id: item_id, repo_name: repo_name, subject: subject, branch: content["head_ref"],
          repo: repo, head_repo: content["head_repo"], pr_number: number, pr_url: pr_url,
          kind: :ci, head_sha: head_sha, comment_at: Time.now.utc.iso8601
        )
      when :green
        # Only cache the green verdict once the PR has settled — checks register
        # over time, so a poll landing right after a push can see only the fast
        # green checks before the slow/failing ones register. Caching then would
        # mark a commit green forever and hide failures that surface seconds later.
        mark_ci_quiet(dir, head_sha) if ci_settled?(content)
        nil
      # :pending / :none — checks aren't done (or haven't registered yet); leave
      # the SHA un-cached so the next poll keeps watching until they complete.
      end
    end

    # How long a PR must be idle (no new push/comment/check event bumping its
    # updated_at) before an all-green reading is trusted enough to cache — long
    # enough that every workflow for the head commit has registered its checks.
    CI_SETTLE_SECONDS = 180

    def ci_settled?(content)
      updated = content["updated_at"].to_s
      return false if updated.empty?
      Time.now - Time.parse(updated) > CI_SETTLE_SECONDS
    rescue ArgumentError
      false
    end

    # Remember that a commit's CI came back green so we don't re-poll check runs
    # for it. Separate from ci_acted_sha (a failure we chased) since it must NOT
    # touch the attempt counter.
    def mark_ci_quiet(dir, head_sha)
      state = gh_state(dir)
      state["ci_quiet_sha"] = head_sha
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Post a single "I'm giving up on CI" note once the attempt cap is hit, so a
    # maintainer knows chomper has stopped retrying. Guarded by ci_gave_up so it
    # posts exactly once per PR.
    def announce_ci_give_up(dir, repo, number, state)
      return if state["ci_gave_up"]
      @github.add_issue_comment(
        repo, number,
        "🤖 CI is still failing after #{@ctx.ci_max_attempts} automatic fix attempt(s) — " \
        "this one needs a human. I'll stop retrying CI for this PR."
      )
      state["ci_gave_up"] = true
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    rescue => e
      log_script "gh-agent: CI give-up notice failed on #{repo}##{number} — #{e.message}"
    end

    # [change_id, repo_name] for a spec PR dir. The repo is whichever one the
    # change's tracker.json recorded at intake — the PR's own base repo is the
    # bot's FORK ("<bot>/openproject"), which no registry entry matches.
    def spec_identity(dir)
      change_id = dir.basename.to_s
      repo_name = tracker_repo(change_id) || @ctx.default_repo.name
      [change_id, repo_name]
    end

    # A change's tracker.json lives in the canonical store, whose path depends on
    # the repo — so this searches the stores rather than assuming one.
    # Memoised: the mapping is immutable once the change exists, and gh-agent
    # polls every 20s — re-statting every registry store on each tick is pure
    # waste. ChangeStore owns the layout; spelling it out here as a path literal
    # would break silently (falling back to the default repo, and revising in
    # the wrong clone) the moment the store moved.
    def tracker_repo(change_id)
      @tracker_repos ||= {}
      return @tracker_repos[change_id] if @tracker_repos.key?(change_id)

      @tracker_repos[change_id] = @ctx.repos.all.filter_map do |repo|
        tracker = ChangeStore.new(@ctx, repo).change_dir(change_id) / "tracker.json"
        next unless tracker.exist?
        name = (Helpers.safe_json_read(tracker) || {})["repo"]
        name if name && @ctx.repos[name]
      end.first
    end

    # The title to show Claude. A shipped PR has a work-package mirror beside it;
    # a spec PR has none, so its PR title is the only name it has.
    def default_subject(dir, content, spec:)
      return content["title"].to_s if spec
      item = Helpers.safe_json_read(dir.parent.parent / "item.json") || {}
      item["subject"].to_s.empty? ? content["title"].to_s : item["subject"].to_s
    end

    # The one recognised PR command word: "@chomper refresh" asks for the full
    # `pr`-command treatment of this PR (GhAgent hands it to PrRunner). Any
    # other trigger text is a plain comment for Claude to converse over.
    def parse_command(body)
      :refresh if body.to_s.match?(/#{mention_re.source}\s+refresh\b/i)
    end

    def allowed?(login, pr_url)
      return true if @ctx.allowed_gh_users.empty?
      ok = @ctx.allowed_gh_users.include?(login.to_s.downcase)
      puts "  [gh-agent] Ignoring @chomper from #{login.inspect} on #{pr_url} — not in allowlist" unless ok
      ok
    end
  end
end
