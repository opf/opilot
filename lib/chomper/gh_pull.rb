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
  GhIntent = Struct.new(:item_id, :repo_name, :subject, :branch, :repo, :head_repo, :pr_number, :pr_url,
                        :kind, :comment_id, :in_reply_to, :text, :user_login, :comment_at, :reply_only,
                        keyword_init: true)

  # The GitHub counterpart of Pull: scans the PRs chomper has already opened (one
  # per items/<id>/pr_url.txt) for new @chomper comments.
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

    def initialize(ctx, github: Clients::GitHub.new(ctx.github_token))
      @ctx    = ctx
      @github = github
    end

    attr_reader :scanned_count

    # The per-repo PR dirs gh-agent watches: items/<id>/repos/<name>/ holding a
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
    def poll_intents(scan_from_at)
      @scan_from_at = scan_from_at
      dirs = shipped_pr_dirs
      @scanned_count = dirs.length
      intents = []
      dirs.each do |d|
        break if Chomper.stopping?
        intents.concat(intents_for_dir(d))
      end
      intents
    end

    # The per-repo PR dir items/<id>/repos/<name>/ for an intent's WP + repo.
    def pr_dir(item_id, repo_name)
      Helpers.item_dir(@ctx, item_id) / "repos" / repo_name.to_s
    end

    # Advance a PR's replay cutoff past a comment we've acted on (mirrors
    # Pull#mark_acted). Keyed by item id + repo so each PR tracks its own state.
    def mark_acted(item_id, repo_name, comment_at)
      dir   = pr_dir(item_id, repo_name)
      state = gh_state(dir)
      state["last_acted_comment_at"] = [state["last_acted_comment_at"], comment_at].compact.max
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Remember a reply chomper posted so its own comment is never re-detected as
    # a trigger (mirrors Pull#record_chomper_comment). Capped so the list can't
    # grow without bound on a long-lived PR.
    def record_chomper_comment(item_id, repo_name, comment_id)
      return unless comment_id
      dir   = pr_dir(item_id, repo_name)
      state = gh_state(dir)
      ids   = (state["chomper_comment_ids"] || []).map(&:to_s)
      ids << comment_id.to_s unless ids.include?(comment_id.to_s)
      state["chomper_comment_ids"] = ids.last(200)
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    private

    # `dir` is items/<id>/repos/<name>/ — the repo subdir holds the PR url, cache,
    # and act-state; item.json/plan.md live one level up at the WP root.
    def intents_for_dir(dir)
      repo_name = dir.basename.to_s
      item_dir  = dir.parent.parent
      pr_url = (dir / "pr_url.txt").read.strip
      repo   = Clients::GitHub.repo_from_url(pr_url)
      number = Clients::GitHub.pr_number_from_url(pr_url)
      return [] unless repo && number

      pr = @github.pull_request(repo, number)
      # Don't touch PRs that are merged or closed — only ones still in review.
      return [] unless pr.state.to_s == "open"

      content = fetch_pr_content(dir, repo, number, pr)

      item    = Helpers.safe_json_read(item_dir / "item.json") || {}
      item_id = item_dir.basename.to_s
      subject = item["subject"].to_s.empty? ? content["title"].to_s : item["subject"].to_s

      state  = gh_state(dir)
      cutoff = [state["last_acted_comment_at"], @scan_from_at].compact.max
      acted  = (state["chomper_comment_ids"] || []).map(&:to_s)

      fresh_mentions(content["comments"], cutoff, acted).filter_map do |c|
        # Off-allowlist comments still advance the cutoff so we don't re-evaluate
        # them every poll (mirrors Pull#intent_from_comments).
        unless allowed?(c["author"], pr_url)
          mark_acted(item_id, repo_name, c["created_at"])
          next nil
        end
        # 👀 the trigger comment so the commenter sees it's being worked on,
        # mirroring the OpenProject agent's react_eyes.
        @github.react(repo, c["id"], kind: c["kind"].to_sym)
        GhIntent.new(
          item_id: item_id, repo_name: repo_name, subject: subject, branch: content["head_ref"], repo: repo,
          head_repo: content["head_repo"], pr_number: number, pr_url: pr_url,
          kind: c["kind"].to_sym, comment_id: c["id"], in_reply_to: c["in_reply_to"],
          text: c["body"], user_login: c["author"], comment_at: c["created_at"]
        )
      end
    rescue => e
      # One unreachable/renamed PR shouldn't stop the others being polled.
      log_script "gh-agent: skipping #{dir.basename} — #{e.message}"
      []
    end

    def allowed?(login, pr_url)
      return true if @ctx.allowed_gh_users.empty?
      ok = @ctx.allowed_gh_users.include?(login.to_s.downcase)
      puts "  [gh-agent] Ignoring @chomper from #{login.inspect} on #{pr_url} — not in allowlist" unless ok
      ok
    end
  end
end
