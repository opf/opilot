require "json"
require "time"
require_relative "clients"

module Chomper
  # A comment on a chomper PR that mentions @chomper, normalised so GhAgent can
  # act on it. `kind` is :issue (the PR conversation thread) or :review (inline
  # on a diff line); review comments carry `comment_id`, and `in_reply_to` points
  # at the parent comment when the trigger is a reply in a review thread (e.g. you
  # answering a Copilot finding) so Claude can be pointed at the right feedback.
  # `repo` is the base repo the PR targets (where comments are posted); `head_repo`
  # is where the PR's branch actually lives (the user's fork) — what gh-agent
  # fetches from and prints a push command against.
  GhIntent = Struct.new(:item_id, :subject, :branch, :repo, :head_repo, :pr_number, :pr_url,
                        :kind, :comment_id, :in_reply_to, :text, :user_login, :comment_at,
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

    MENTION = /@chomper\b/i

    def initialize(ctx, github: Clients::GitHub.new(ctx.github_token))
      @ctx    = ctx
      @github = github
    end

    attr_reader :scanned_count

    # The item dirs gh-agent watches: those holding a shipped PR.
    def shipped_item_dirs
      dir = Helpers.items_dir(@ctx)
      return [] unless dir.exist?
      dir.children.select(&:directory?).sort
         .select { |d| Helpers.file_has_content?(d / "pr_url.txt") }
    end

    # Poll every watched PR and return the new @chomper comments as GhIntents,
    # oldest first so a review's several inline comments are each handled in turn.
    # `scan_from_at` (ISO8601) is the floor cutoff entered at startup.
    def poll_intents(scan_from_at)
      @scan_from_at = scan_from_at
      dirs = shipped_item_dirs
      @scanned_count = dirs.length
      dirs.flat_map { |d| intents_for_dir(d) }
    end

    # Advance a PR's replay cutoff past a comment we've acted on (mirrors
    # Pull#mark_acted). Keyed by item id so GhAgent needn't carry the dir.
    def mark_acted(item_id, comment_at)
      dir   = Helpers.item_dir(@ctx, item_id)
      state = gh_state(dir)
      state["last_acted_comment_at"] = [state["last_acted_comment_at"], comment_at].compact.max
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    # Remember a reply chomper posted so its own comment is never re-detected as
    # a trigger (mirrors Pull#record_chomper_comment). Capped so the list can't
    # grow without bound on a long-lived PR.
    def record_chomper_comment(item_id, comment_id)
      return unless comment_id
      dir   = Helpers.item_dir(@ctx, item_id)
      state = gh_state(dir)
      ids   = (state["chomper_comment_ids"] || []).map(&:to_s)
      ids << comment_id.to_s unless ids.include?(comment_id.to_s)
      state["chomper_comment_ids"] = ids.last(200)
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
    end

    private

    def intents_for_dir(dir)
      pr_url = (dir / "pr_url.txt").read.strip
      repo   = Clients::GitHub.repo_from_url(pr_url)
      number = Clients::GitHub.pr_number_from_url(pr_url)
      return [] unless repo && number

      pr = @github.pull_request(repo, number)
      # Don't touch PRs that are merged or closed — only ones still in review.
      return [] unless pr.state.to_s == "open"

      content = fetch_pr_content(dir, repo, number, pr)

      item    = Helpers.safe_json_read(dir / "item.json") || {}
      item_id = dir.basename.to_s
      subject = item["subject"].to_s.empty? ? content["title"].to_s : item["subject"].to_s

      state  = gh_state(dir)
      cutoff = [state["last_acted_comment_at"], @scan_from_at].compact.max
      acted  = (state["chomper_comment_ids"] || []).map(&:to_s)

      fresh = content["comments"]
        .reject { |c| acted.include?(c["id"].to_s) }
        .select { |c| c["body"] =~ MENTION }
        .select { |c| cutoff.nil? || c["created_at"] > cutoff }
        .sort_by { |c| c["created_at"] }

      fresh.filter_map do |c|
        # Off-allowlist comments still advance the cutoff so we don't re-evaluate
        # them every poll (mirrors Pull#intent_from_comments).
        unless allowed?(c["author"], pr_url)
          mark_acted(item_id, c["created_at"])
          next nil
        end
        # 👀 the trigger comment so the commenter sees it's being worked on,
        # mirroring the OpenProject agent's react_eyes.
        @github.react(repo, c["id"], kind: c["kind"].to_sym)
        GhIntent.new(
          item_id: item_id, subject: subject, branch: content["head_ref"], repo: repo,
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

    # Cache the PR's content the way Pull#fetch_work_package_item caches a WP:
    # reuse the saved pr.json while the PR's updated_at is unchanged, otherwise
    # re-fetch every comment + review stream and rewrite it. The cache is what
    # GhAgent hands Claude for full PR context (Copilot's review included).
    def fetch_pr_content(dir, repo, number, pr)
      cache_path = dir / "pr.json"
      updated_at = to_iso(pr.updated_at)
      cached = Helpers.safe_json_read(cache_path)
      return cached if cached && cached["updated_at"] == updated_at

      comments = @github.issue_comments(repo, number).map { |c| issue_comment(c) } +
                 @github.review_comments(repo, number).map { |c| review_comment(c) }
      reviews  = @github.reviews(repo, number).map { |r| review_summary(r) }

      data = {
        "number"     => number,        "repo"       => repo,
        "url"        => pr.html_url,    "title"      => pr.title,
        "state"      => pr.state,       "updated_at" => updated_at,
        "head_ref"   => pr.head.ref,    "head_sha"   => pr.head.sha,
        # Where the branch lives — the fork for a cross-repo PR (nil only if the
        # head fork was deleted, which would have closed the PR anyway).
        "head_repo"  => pr.head.repo&.full_name,
        "comments"   => comments,       "reviews"    => reviews
      }
      Helpers.write_json_atomic(cache_path, data, "pr")
      data
    end

    def issue_comment(c)
      {
        "id" => c.id, "kind" => "issue", "author" => c.user&.login.to_s,
        "created_at" => to_iso(c.created_at), "body" => c.body.to_s, "in_reply_to" => nil
      }
    end

    def review_comment(c)
      {
        "id" => c.id, "kind" => "review", "author" => c.user&.login.to_s,
        "created_at" => to_iso(c.created_at), "body" => c.body.to_s,
        "in_reply_to" => c.in_reply_to_id, "path" => c.path,
        "line" => (c.respond_to?(:line) ? c.line : nil), "diff_hunk" => c.diff_hunk
      }
    end

    def review_summary(r)
      {
        "id" => r.id, "author" => r.user&.login.to_s, "state" => r.state,
        "submitted_at" => to_iso(r.submitted_at), "body" => r.body.to_s
      }
    end

    # Octokit hands back a Time; normalise to the same ISO8601 string form the
    # cutoff and cache key are stored in, so comparisons are plain string compares.
    def to_iso(time)
      return nil if time.nil?
      time.respond_to?(:utc) ? time.utc.iso8601 : Time.parse(time.to_s).utc.iso8601
    end

    def allowed?(login, pr_url)
      return true if @ctx.allowed_gh_users.empty?
      ok = @ctx.allowed_gh_users.include?(login.to_s.downcase)
      puts "  [gh-agent] Ignoring @chomper from #{login.inspect} on #{pr_url} — not in allowlist" unless ok
      ok
    end

    def gh_state(dir)
      Helpers.safe_json_read(dir / "gh_pr.json") || {}
    end
  end
end
