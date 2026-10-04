require "json"

module OPilot
  module GitHub
    # gh-agent's second source: @opilot mentions on the registry repos' *upstream*
    # PRs. Other people's PRs only — the bot's own are GitHub::Pull's territory, and
    # serving them here too would double-handle every comment (separate act-state).
    # No write access here, so intents are `reply_only`: answer, or offer GitHub
    # suggestions, never push.
    #
    # The search API is a cheap pre-filter, so comments and an LLM call are only
    # spent on PRs that really mention the bot. OFF unless
    # OPILOT_TRACK_UPSTREAM_PRS is set AND OPILOT_ALLOWED_GH_USERS is non-empty
    # (see #enabled?) — this is the one source reaching outside opilot's own PRs.
    #
    # Per-PR state: .opilot/pr_reviews/<owner>-<repo>/<number>/, cache and
    # act-state split as in GitHub::Pull. The directory name predates the "not a review"
    # framing; renaming it would orphan every tracked PR's act-state.
    class UpstreamPull
      include Helpers
      include GitHub::PrCache

      def initialize(ctx, github: Clients::GitHub.new(ctx.contributor_token))
        @ctx    = ctx
        @github = github
      end

      attr_reader :scanned_count

      # Two gates, both required. OPILOT_TRACK_UPSTREAM_PRS is the operator saying
      # "watch other people's PRs at all" — off unless set, so no ordinary agent run
      # reaches outside opilot's own PRs. OPILOT_ALLOWED_GH_USERS then says whose
      # mentions count; without it an @opilot on any public PR could spend tokens.
      def enabled?
        @ctx.track_upstream_prs? && @ctx.allowed_gh_users.any?
      end

      # Poll every registry repo's upstream for fresh @opilot mentions and return
      # them as reply_only GhIntents, oldest first.
      def poll_intents(scan_from_at)
        @scan_from_at  = scan_from_at
        @scanned_count = 0
        return [] unless enabled?

        hits = discover(@ctx.repos.all.map(&:upstream).uniq)
        @scanned_count = hits.length
        hits.flat_map do |hit|
          repo = registry_repo_for(hit)
          repo ? intents_for_pr(repo, hit.number) : []
        end
      end

      # The per-PR state dir .opilot/pr_reviews/<owner>-<repo>/<number>/.
      def pr_dir(repo_str, number)
        dir = @ctx.state_dir / "pr_reviews" / repo_str.to_s.tr("/", "-") / number.to_s
        dir.mkpath
        dir
      end

      def mark_acted(repo_str, number, comment_at)
        advance_cutoff(pr_dir(repo_str, number), comment_at)
      end

      def record_opilot_comment(repo_str, number, comment_id)
        append_opilot_comment(pr_dir(repo_str, number), comment_id)
      end

      private

      # PRs on `upstream` that mention the opilot bot and changed since the cutoff.
      # Uses GitHub's `mentions:<login>` qualifier against the bot's actual GitHub
      # login (e.g. op-opilot), resolved programmatically — the same handle
      # mention_re matches — rather than a hardcoded "@opilot". The bot's own PRs
      # are excluded (`-author:`): they are GitHub::Pull's territory — it can push there
      # and parses commands like refresh — and this scanner's separate act-state
      # would otherwise re-handle their comments a second time, reply-only.
      #
      # Several `repo:` qualifiers OR together, so one search covers many
      # upstreams. The search API allows 30 calls a minute, and one call per
      # upstream per tick used most of that. Chunked to stay under the 256-char
      # query limit.
      def discover(upstreams)
        date = @scan_from_at.to_s[0, 10]   # YYYY-MM-DD for the search qualifier
        ping = bot_login.empty? ? %("@opilot") : "mentions:#{bot_login} -author:#{bot_login}"
        tail = "is:pr is:open #{ping} updated:>=#{date}"
        repo_chunks(upstreams, MAX_QUERY - tail.length - 1)
          .flat_map { |repos| @github.search_prs("#{repos} #{tail}", per_page: 100) }
      end

      MAX_QUERY = 256

      def repo_chunks(upstreams, budget)
        upstreams.each_with_object([]) do |upstream, chunks|
          term = "repo:#{upstream}"
          if chunks.last && chunks.last.length + 1 + term.length <= budget
            chunks.last << " " << term
          else
            chunks << term.dup
          end
        end
      end

      # The registry repo a search hit belongs to, from its `repository_url`
      # (".../repos/<owner>/<repo>"). Exact match only: Registry#by_upstream
      # falls back to the default repo.
      def registry_repo_for(hit)
        owner_repo = hit.repository_url.to_s.split("/repos/", 2).last
        @ctx.repos.all.find { |r| r.upstream.casecmp?(owner_repo.to_s) }
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
        acted   = (state["opilot_comment_ids"] || []).map(&:to_s)

        ci_read = false
        fresh_mentions(content["comments"], cutoff, acted).filter_map do |c|
          unless allowed?(c["author"], content["url"])
            mark_acted(repo_str, number, c["created_at"])
            next nil
          end
          @github.react(repo_str, c["id"], kind: c["kind"].to_sym)
          # Populate ci.json once per poll for a PR that will actually be handled,
          # so a review triggered by a CI question has the failure detail on hand.
          # Read-only — opilot can't fix an upstream PR, only explain it.
          unless ci_read
            write_review_ci(dir, repo_str, content)
            ci_read = true
          end
          GitHub::Intent.new(
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
      # questions about red checks (`GitHub::PrCache#fetch_ci_content`, keyed by head
      # SHA). Only a failing run writes the file — green/pending/none leaves it
      # absent and the review runs on the diff + thread alone. Ignored checks
      # (`OPILOT_CI_IGNORE_CHECKS`) are dropped so a fork-only failure like "SaaS
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

      # Unlike GitHub::Pull (open when the allowlist is empty), upstream scanning only
      # runs with an allowlist, so a missing login is always rejected.
      def allowed?(login, pr_url)
        ok = @ctx.allowed_gh_users.include?(login.to_s.downcase)
        puts "  [gh-agent] Ignoring @opilot from #{login.inspect} on #{pr_url} — not in allowlist" unless ok
        ok
      end
    end
  end
end
