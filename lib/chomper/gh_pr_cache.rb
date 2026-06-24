require "json"
require "time"

module Chomper
  # Shared PR-content plumbing for the two GitHub pollers: GhPull (chomper's own
  # PRs) and UpstreamGhPull (any upstream PR that @-mentions chomper). Both cache a
  # PR's comments+reviews keyed by its updated_at, recognise an @chomper mention,
  # and filter a PR's comments down to the fresh, un-acted ones. Expects the
  # including class to define `@github` and `@ctx`.
  module GhPrCache
    # A comment triggers chomper when it contains the literal `@chomper` or an
    # @-mention of the bot's own GitHub login (e.g. `@chomper-bot`).
    def mention_re
      @mention_re ||= begin
        handles = ["chomper"]
        login = (@github.login rescue nil)
        handles << login if login && !login.empty?
        /(?:#{handles.uniq.map { |h| "@#{Regexp.escape(h)}" }.join("|")})\b/i
      end
    end

    # The comments worth acting on: not already replied to by chomper, mentioning
    # @chomper, newer than the cutoff — oldest first so a review's several inline
    # comments are each handled in turn.
    def fresh_mentions(comments, cutoff, acted)
      comments
        .reject { |c| acted.include?(c["id"].to_s) }
        .select { |c| c["body"] =~ mention_re }
        .select { |c| cutoff.nil? || c["created_at"] > cutoff }
        .sort_by { |c| c["created_at"] }
    end

    # Cache the PR's content the way Pull caches a WP: reuse the saved pr.json
    # while updated_at is unchanged, otherwise re-fetch every comment + review
    # stream and rewrite it. The cache is what the agent hands Claude for full PR
    # context (Copilot's review included).
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

    def gh_state(dir)
      Helpers.safe_json_read(dir / "gh_pr.json") || {}
    end

    private

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
  end
end
