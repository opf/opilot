require "json"
require_relative "clients"
require_relative "gh_pr_cache"

module Chomper
  # The second GitHub source for gh-agent: scans the *upstream* PRs of every
  # registry repo (e.g. opf/openproject) for @chomper mentions — other people's
  # PRs only, never the bot's own (those are GhPull's territory, with push
  # rights and command parsing; serving them here too would double-handle every
  # comment). chomper has no write access to these PRs' branches, so the
  # intents it yields are flagged `reply_only` — gh-agent reviews/answers but
  # never pushes code.
  #
  # Discovery uses the GitHub search API as a cheap pre-filter
  # (`repo:<upstream> is:pr is:open mentions:<bot-login> updated:>=<cutoff>`, the
  # login resolved programmatically) so we only fetch comments + spend a Claude
  # call on PRs that actually mention the chomper bot.
  # An empty CHOMPER_ALLOWED_GH_USERS disables this scan entirely — an open
  # @chomper trigger across huge public repos would be a spend/abuse risk.
  #
  # Per-PR state lives under .chomper/pr_reviews/<owner>-<repo>/<number>/,
  # mirroring how GhPull keeps a PR's cache (pr.json) and act-state (gh_pr.json)
  # separate.
  class UpstreamGhPull
    include Helpers
    include GhPrCache

    def initialize(ctx, github: Clients::GitHub.new(ctx.github_token))
      @ctx    = ctx
      @github = github
    end

    attr_reader :scanned_count

    # True when upstream scanning is active (it requires an allowlist).
    def enabled?
      @ctx.allowed_gh_users.any?
    end

    # Poll every registry repo's upstream for fresh @chomper mentions and return
    # them as reply_only GhIntents, oldest first.
    def poll_intents(scan_from_at)
      @scan_from_at  = scan_from_at
      @scanned_count = 0
      return [] unless enabled?

      intents = []
      @ctx.repos.all.each do |repo|
        break if Chomper.stopping?
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

      fresh_mentions(content["comments"], cutoff, acted).filter_map do |c|
        unless allowed?(c["author"], content["url"])
          mark_acted(repo_str, number, c["created_at"])
          next nil
        end
        @github.react(repo_str, c["id"], kind: c["kind"].to_sym)
        GhIntent.new(
          item_id: nil, repo_name: registry_repo.name, subject: subject,
          branch: content["head_ref"], repo: repo_str, head_repo: content["head_repo"],
          pr_number: number, pr_url: content["url"], kind: c["kind"].to_sym,
          comment_id: c["id"], in_reply_to: c["in_reply_to"], text: c["body"],
          user_login: c["author"], comment_at: c["created_at"], reply_only: true
        )
      end
    rescue => e
      # One unreachable/renamed PR shouldn't stop the others being polled.
      log_script "gh-agent(upstream): skipping #{repo_str}##{number} — #{e.message}"
      []
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
