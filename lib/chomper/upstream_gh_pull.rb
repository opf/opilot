require "json"
require_relative "clients"
require_relative "gh_pr_cache"

module Chomper
  # gh-agent's second source: @chomper mentions on the registry repos' *upstream*
  # PRs. Other people's PRs only — the bot's own are GhPull's territory, and
  # serving them here too would double-handle every comment (separate act-state).
  # No write access here, so intents are `reply_only`: answer, or offer GitHub
  # suggestions, never push.
  #
  # The search API is a cheap pre-filter, so comments and a Claude call are only
  # spent on PRs that really mention the bot. OFF unless
  # CHOMPER_TRACK_UPSTREAM_PRS is set AND CHOMPER_ALLOWED_GH_USERS is non-empty
  # (see #enabled?) — this is the one source reaching outside chomper's own PRs.
  #
  # Per-PR state: .chomper/pr_reviews/<owner>-<repo>/<number>/, cache and
  # act-state split as in GhPull. The directory name predates the "not a review"
  # framing; renaming it would orphan every tracked PR's act-state.
  class UpstreamGhPull
    include Helpers
    include GhPrCache

    def initialize(ctx, github: Clients::GitHub.new(ctx.contributor_token))
      @ctx    = ctx
      @github = github
    end

    attr_reader :scanned_count

    # Two gates, both required. CHOMPER_TRACK_UPSTREAM_PRS is the operator saying
    # "watch other people's PRs at all" — off unless set, so no ordinary agent run
    # reaches outside chomper's own PRs. CHOMPER_ALLOWED_GH_USERS then says whose
    # mentions count; without it an @chomper on any public PR could spend tokens.
    def enabled?
      @ctx.track_upstream_prs? && @ctx.allowed_gh_users.any?
    end

    # Poll every registry repo's upstream for fresh @chomper mentions and return
    # them as reply_only GhIntents, oldest first.
    def poll_intents(scan_from_at)
      @scan_from_at  = scan_from_at
      @scanned_count = 0
      return [] unless enabled?

      intents = []
      @ctx.repos.all.each do |repo|
        refs = discover(repo.upstream)
        @scanned_count += refs.length
        refs.each { |ref| intents.concat(intents_for_pr(repo, ref.number)) }
      end
      intents
    end

    # The per-PR state dir .chomper/pr_reviews/<owner>-<repo>/<number>/.
    def pr_dir(repo_str, number)
      dir = @ctx.state_dir / "pr_reviews" / repo_str.to_s.tr("/", "-") / number.to_s
      dir.mkpath
      dir
    end

    def mark_acted(repo_str, number, comment_at)
      dir   = pr_dir(repo_str, number)
      state = gh_state(dir)
      state["last_acted_comment_at"] = [state["last_acted_comment_at"], comment_at].compact.max
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    def record_chomper_comment(repo_str, number, comment_id)
      return unless comment_id
      dir   = pr_dir(repo_str, number)
      state = gh_state(dir)
      ids   = (state["chomper_comment_ids"] || []).map(&:to_s)
      ids << comment_id.to_s unless ids.include?(comment_id.to_s)
      state["chomper_comment_ids"] = ids.last(200)
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    private

    # PRs on `upstream` that mention the chomper bot and changed since the cutoff.
    # Uses GitHub's `mentions:<login>` qualifier against the bot's actual GitHub
    # login (e.g. op-chomper), resolved programmatically — the same handle
    # mention_re matches — rather than a hardcoded "@chomper". The bot's own PRs
    # are excluded (`-author:`): they are GhPull's territory — it can push there
    # and parses commands like refresh — and this scanner's separate act-state
    # would otherwise re-handle their comments a second time, reply-only.
    def discover(upstream)
      date = @scan_from_at.to_s[0, 10]   # YYYY-MM-DD for the search qualifier
      ping = bot_login.empty? ? %("@chomper") : "mentions:#{bot_login} -author:#{bot_login}"
      @github.search_prs(%(repo:#{upstream} is:pr is:open #{ping} updated:>=#{date}))
    end

    # The bot account's GitHub login, memoized (falls back to "" if unavailable,
    # so discover degrades to a literal text search rather than a malformed query).
    def bot_login
      @bot_login ||= (@github.login.to_s rescue "")
    end

    def intents_for_pr(registry_repo, number)
      repo_str = registry_repo.upstream
      dir = pr_dir(repo_str, number)
      pr  = @github.pull_request(repo_str, number)
      return [] unless pr.state.to_s == "open"
      # Backstop for the search-side -author: filter (which the literal-text
      # fallback query can't express): never serve the bot's own PRs here.
      return [] if own_pr?(pr)

      content = fetch_pr_content(dir, repo_str, number, pr)
      subject = content["title"].to_s
      state   = gh_state(dir)
      cutoff  = [state["last_acted_comment_at"], @scan_from_at].compact.max
      acted   = (state["chomper_comment_ids"] || []).map(&:to_s)

      ci_read = false
      fresh_mentions(content["comments"], cutoff, acted).filter_map do |c|
        unless allowed?(c["author"], content["url"])
          mark_acted(repo_str, number, c["created_at"])
          next nil
        end
        @github.react(repo_str, c["id"], kind: c["kind"].to_sym)
        # Populate ci.json once per poll for a PR that will actually be handled,
        # so a review triggered by a CI question has the failure detail on hand.
        # Read-only — chomper can't fix an upstream PR, only explain it.
        unless ci_read
          write_review_ci(dir, repo_str, content)
          ci_read = true
        end
        GhIntent.new(
          item_id: nil, repo_name: registry_repo.name, subject: subject,
          branch: content["head_ref"], repo: repo_str, head_repo: content["head_repo"],
          pr_number: number, pr_url: content["url"], kind: c["kind"].to_sym,
          comment_id: c["id"], in_reply_to: c["in_reply_to"], text: c["body"],
          user_login: c["author"], comment_at: c["created_at"], reply_only: true,
          head_sha: content["head_sha"]
        )
      end
    rescue => e
      # One unreachable/renamed PR shouldn't stop the others being polled.
      log_script "gh-agent(upstream): skipping #{repo_str}##{number} — #{e.message}"
      []
    end

    # Cache the PR's CI-failure detail to ci.json so a review can answer
    # questions about red checks (`GhPrCache#fetch_ci_content`, keyed by head
    # SHA). Only a failing run writes the file — green/pending/none leaves it
    # absent and the review runs on the diff + thread alone. Ignored checks
    # (`CHOMPER_CI_IGNORE_CHECKS`) are dropped so a fork-only failure like "SaaS
    # tests" doesn't masquerade as the problem. Best-effort: a CI-read hiccup
    # (rate limit, expired logs) must never block the review reply.
    def write_review_ci(dir, repo_str, content)
      head_sha = content["head_sha"].to_s
      return if head_sha.empty?
      ignore     = @ctx.ci_ignored_checks
      check_runs = @github.check_runs(repo_str, head_sha)
                          .reject { |c| ignore.include?(c.name.to_s.strip.downcase) }
      fetch_ci_content(dir, repo_str, head_sha, check_runs, ignore: ignore) if ci_status(check_runs) == :failed
    rescue => e
      log_script "gh-agent(upstream): CI read failed for #{repo_str}##{content['number']} — #{e.message}"
    end

    # A PR opened by the bot account itself (fork mode's cross-repo PRs and
    # direct mode's same-repo PRs are both authored by the token's login).
    def own_pr?(pr)
      !bot_login.empty? && pr.user&.login.to_s.casecmp?(bot_login)
    end

    # Unlike GhPull (open when the allowlist is empty), upstream scanning only
    # runs with an allowlist, so a missing login is always rejected.
    def allowed?(login, pr_url)
      ok = @ctx.allowed_gh_users.include?(login.to_s.downcase)
      puts "  [gh-agent] Ignoring @chomper from #{login.inspect} on #{pr_url} — not in allowlist" unless ok
      ok
    end
  end
end
