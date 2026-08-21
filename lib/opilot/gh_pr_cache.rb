require "json"
require "time"

module OPilot
  # Shared PR-content plumbing for the two GitHub pollers: GhPull (opilot's own
  # PRs) and UpstreamGhPull (any upstream PR that @-mentions opilot). Both cache a
  # PR's comments+reviews keyed by its updated_at, recognise an @opilot mention,
  # and filter a PR's comments down to the fresh, un-acted ones. Expects the
  # including class to define `@github` and `@ctx`.
  module GhPrCache
    # A comment triggers opilot when it contains the literal `@opilot` or an
    # @-mention of the bot's own GitHub login (e.g. `@opilot-bot`).
    def mention_re
      @mention_re ||= begin
        handles = ["opilot"]
        login = (@github.login rescue nil)
        handles << login if login && !login.empty?
        /(?:#{handles.uniq.map { |h| "@#{Regexp.escape(h)}" }.join("|")})\b/i
      end
    end

    # The comments worth acting on: not already replied to by opilot, mentioning
    # @opilot, newer than the cutoff — oldest first so a review's several inline
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
    # stream and rewrite it. The cache is what the agent hands the LLM for full PR
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

    # Read gh_pr.json, let the block mutate it, write it back — the shape every
    # act-state update in both pollers takes.
    #
    # It always writes. A caller that must NOT write when nothing changed
    # (GhPull#clear_pr_done — a routine `dev refresh` should not churn the state
    # file of a PR that was never closed) checks the state before calling.
    def update_gh_state(dir)
      state = gh_state(dir)
      yield state
      Helpers.write_json_atomic(dir / "gh_pr.json", state, "gh_pr")
      state
    end

    # Remember a reply opilot posted so its own comment is never re-detected as
    # a trigger (mirrors Pull#record_opilot_comment). Capped so the list cannot
    # grow without bound on a long-lived PR. Identical for both pollers — only
    # the way each resolves `dir` differs.
    def append_opilot_comment(dir, comment_id)
      return unless comment_id
      update_gh_state(dir) do |state|
        ids = (state["opilot_comment_ids"] || []).map(&:to_s)
        ids << comment_id.to_s unless ids.include?(comment_id.to_s)
        state["opilot_comment_ids"] = ids.last(200)
      end
    end

    # Check-run conclusions that mean the PR's CI is broken in a way worth a
    # fix attempt. `cancelled`/`skipped`/`neutral`/`success` are not actionable.
    CI_FAILURE_CONCLUSIONS = %w[failure timed_out action_required startup_failure].freeze

    # Classify a commit's check runs: :none (no CI reported yet), :failed (≥1
    # completed check has already failed), :pending (nothing failed yet but a
    # check is still running/queued), or :green (all done, none failed). :failed
    # wins over :pending so a fast failure (e.g. yamllint) is fixed immediately
    # rather than waiting on the slow jobs — a pushed fix re-runs everything
    # anyway. Only :failed triggers a CI-fix intent; :green is cached as quiet.
    def ci_status(check_runs)
      return :none if check_runs.nil? || check_runs.empty?
      return :failed if check_runs.any? { |c| ci_failed?(c) }
      return :pending if check_runs.any? { |c| c.status.to_s != "completed" }
      :green
    end

    def ci_failed?(check_run)
      check_run.status.to_s == "completed" &&
        CI_FAILURE_CONCLUSIONS.include?(check_run.conclusion.to_s)
    end

    # Cache a head SHA's CI failure detail to ci.json the way pr.json caches PR
    # content — but keyed by the head SHA, since a new CI run rarely bumps the
    # PR's updated_at. Pulls each failed check's output summary + annotations and
    # each failed Actions job's log tail, matching a log to its check by name (a
    # GitHub Actions check run's name is its job name). Reused while the SHA is
    # unchanged so logs aren't re-downloaded every poll. Returns the data hash.
    def fetch_ci_content(dir, repo, head_sha, check_runs, ignore: [])
      cache_path = dir / "ci.json"
      cached = Helpers.safe_json_read(cache_path)
      return cached if cached && cached["head_sha"] == head_sha

      failed = check_runs.select { |c| ci_failed?(c) }
      by_name = {}
      entries = failed.map do |c|
        entry = {
          "name"        => c.name.to_s,
          "conclusion"  => c.conclusion.to_s,
          "summary"     => check_summary(c),
          "annotations" => check_annotations(repo, c),
          "log_excerpt" => nil
        }
        by_name[c.name.to_s] = entry
        entry
      end

      # Attach each failed job's log tail to its check entry by name, adding an
      # entry for any failed job that has no matching check run.
      @github.workflow_runs(repo, head_sha).each do |run|
        @github.workflow_run_jobs(repo, run.id).each do |job|
          next unless CI_FAILURE_CONCLUSIONS.include?(job.conclusion.to_s)
          next if ignore.include?(job.name.to_s.strip.downcase)
          log = @github.job_log(repo, job.id)
          next unless log
          entry = by_name[job.name.to_s]
          unless entry
            entry = { "name" => job.name.to_s, "conclusion" => job.conclusion.to_s,
                      "summary" => nil, "annotations" => [], "log_excerpt" => nil }
            by_name[job.name.to_s] = entry
            entries << entry
          end
          entry["log_excerpt"] = log
        end
      end

      data = { "head_sha" => head_sha, "fetched_at" => to_iso(Time.now), "failed" => entries }
      Helpers.write_json_atomic(cache_path, data, "ci")
      data
    end

    private

    def check_summary(c)
      out = c.output or return nil
      [out.title, out.summary, out.text].map { |s| s.to_s.strip }.reject(&:empty?).join("\n\n")
    end

    def check_annotations(repo, c)
      out = c.output
      return [] unless out && out.annotations_count.to_i.positive?
      @github.check_run_annotations(repo, c.id).map do |a|
        { "path" => a.path, "line" => (a.start_line rescue nil),
          "level" => (a.annotation_level rescue nil), "message" => a.message.to_s }
      end
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
  end
end
