require_relative "../test_helper"

module Chomper
  class GhPullTest < Minitest::Test
    User          = Struct.new(:login)
    Repo          = Struct.new(:full_name)
    Head          = Struct.new(:ref, :sha, :repo)
    PR            = Struct.new(:state, :updated_at, :html_url, :title, :head, keyword_init: true)
    IssueC        = Struct.new(:id, :body, :user, :created_at, keyword_init: true)
    ReviewC       = Struct.new(:id, :body, :user, :created_at, :in_reply_to_id, :path, :line, :diff_hunk, keyword_init: true)
    ReviewSummary = Struct.new(:id, :body, :user, :state, :submitted_at, keyword_init: true)
    CheckOutput   = Struct.new(:title, :summary, :text, :annotations_count, keyword_init: true)
    CheckRun      = Struct.new(:id, :name, :status, :conclusion, :output, keyword_init: true)
    Annotation    = Struct.new(:path, :start_line, :annotation_level, :message, keyword_init: true)
    WfRun         = Struct.new(:id, keyword_init: true)
    WfJob         = Struct.new(:id, :name, :status, :conclusion, keyword_init: true)

    # ctx exposing the reader methods GhPull calls.
    CtxClass = Struct.new(:state_dir, :allowed_gh_users, :github_token, :log_file,
                          :ci_max_attempts, :ci_ignored_checks) do
      def op_host = "test.host"   # WP mirror namespace
    end

    class FakeGitHub
      attr_reader :comment_fetches, :reacted, :ci_comments, :check_runs_calls, :pr_fetches
      def initialize(pr:, issue: [], review: [], reviews: [],
                     check_runs: [], annotations: [], workflow_runs: [], jobs: [], job_log: nil)
        @pr = pr; @issue = issue; @review = review; @reviews = reviews
        @check_runs = check_runs; @annotations = annotations
        @workflow_runs = workflow_runs; @jobs = jobs; @job_log = job_log
        @comment_fetches = 0; @reacted = []; @ci_comments = []; @check_runs_calls = 0
        @pr_fetches = 0
      end
      def pull_request(_repo, _num);   @pr_fetches += 1; @pr; end
      def issue_comments(_repo, _num); @comment_fetches += 1; @issue; end
      def review_comments(_repo, _num); @review;  end
      def reviews(_repo, _num);         @reviews; end
      def react(repo, comment_id, kind:, content: "eyes"); @reacted << [repo, comment_id, kind, content]; end
      def login; "chomper-bot"; end
      def check_runs(_repo, _ref);            @check_runs_calls += 1; @check_runs;  end
      def check_run_annotations(_repo, _id);  @annotations; end
      def workflow_runs(_repo, _sha);         @workflow_runs; end
      def workflow_run_jobs(_repo, _run_id);  @jobs; end
      def job_log(_repo, _job_id, **_);       @job_log; end
      def add_issue_comment(repo, num, body); @ci_comments << [repo, num, body]; nil; end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = CtxClass.new(
        Pathname(@tmpdir) / ".chomper", ["thykel"], "ghtok", Pathname(@tmpdir) / "chomp.log", 2, []
      )
      @dir = @ctx.state_dir / "work_packages" / "test.host" / "42"
      @pr_dir = @dir / "repos" / "openproject"   # per-repo PR subdir
      @pr_dir.mkpath
      (@pr_dir / "pr_url.txt").write("https://github.com/o/r/pull/7\n")
      (@dir / "item.json").write(JSON.generate("subject" => "Fix the bug", "type" => "bug"))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def pr(state: "open", updated_at: "2026-06-18T18:00:00Z", title: "PR title",
           ref: "bug/42-fix-the-bug", head_repo: "fork/r")
      PR.new(state: state, updated_at: Time.parse(updated_at),
             html_url: "https://github.com/o/r/pull/7", title: title,
             head: Head.new(ref, "sha123", Repo.new(head_repo)))
    end

    def issue_c(id:, body:, login:, at:)
      IssueC.new(id: id, body: body, user: User.new(login), created_at: Time.parse(at))
    end

    def review_c(id:, body:, login:, at:, in_reply_to: nil, path: nil, line: nil, diff_hunk: nil)
      ReviewC.new(id: id, body: body, user: User.new(login), created_at: Time.parse(at),
                  in_reply_to_id: in_reply_to, path: path, line: line, diff_hunk: diff_hunk)
    end

    def review_summary(id:, body:, login:, state:, at:)
      ReviewSummary.new(id: id, body: body, user: User.new(login), state: state, submitted_at: Time.parse(at))
    end

    def pull(issue: [], review: [], reviews: [], pr_obj: pr, **ci)
      @github = FakeGitHub.new(pr: pr_obj, issue: issue, review: review, reviews: reviews, **ci)
      GhPull.new(@ctx, github: @github)
    end

    def check_run(status: "completed", conclusion: "failure", name: "RSpec", annotations_count: 0)
      CheckRun.new(id: 1, name: name, status: status, conclusion: conclusion,
                   output: CheckOutput.new(title: "Failures", summary: "1 example failed",
                                           text: nil, annotations_count: annotations_count))
    end

    def test_returns_intent_for_a_chomper_comment
      gh = pull(issue: [issue_c(id: 1, body: "@chomper please guard nil", login: "thykel", at: "2026-06-18T18:05:00Z")])
      intents = gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, intents.length
      i = intents.first
      assert_equal "42", i.item_id
      assert_equal "o/r", i.repo
      assert_equal 7, i.pr_number
      assert_equal :issue, i.kind
      assert_equal "thykel", i.user_login
    end

    def test_carries_the_head_repo_fork_for_fetch_and_push
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
                pr_obj: pr(head_repo: "thykel/openproject"))
      i = gh.poll_intents("2000-01-01T00:00:00Z").first
      assert_equal "o/r", i.repo, "comments are posted on the base repo"
      assert_equal "thykel/openproject", i.head_repo, "the branch lives in the fork"
    end

    def test_uses_the_real_pr_head_ref_for_the_branch
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
                pr_obj: pr(ref: "renamed/branch-after-edit"))
      assert_equal "renamed/branch-after-edit", gh.poll_intents("2000-01-01T00:00:00Z").first.branch
    end

    def test_reacts_eyes_to_the_trigger_comment
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal [["o/r", 1, :issue, "eyes"]], @github.reacted
    end

    def test_does_not_react_to_off_allowlist_comments
      gh = pull(issue: [issue_c(id: 9, body: "@chomper go", login: "rando", at: "2026-06-18T18:05:00Z")])
      gh.poll_intents("2000-01-01T00:00:00Z")
      assert_empty @github.reacted
    end

    def test_review_reply_carries_kind_and_parent
      gh = pull(review: [review_c(id: 5, body: "@chomper fix this", login: "thykel",
                                  at: "2026-06-18T18:05:00Z", in_reply_to: 999, path: "app/x.rb", line: 12)])
      i = gh.poll_intents("2000-01-01T00:00:00Z").first
      assert_equal :review, i.kind
      assert_equal 5, i.comment_id
      assert_equal 999, i.in_reply_to
    end

    def test_skips_closed_or_merged_prs
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
                pr_obj: pr(state: "closed"))
      capture_io { assert_empty gh.poll_intents("2000-01-01T00:00:00Z") }
    end

    def test_a_closed_pr_is_marked_done_and_never_polled_again
      # First poll observes the closure (one metadata call) and records it.
      gh = pull(pr_obj: pr(state: "closed"))
      capture_io { assert_empty gh.poll_intents("2000-01-01T00:00:00Z") }
      assert_equal 1, @github.pr_fetches
      assert JSON.parse((@pr_dir / "gh_pr.json").read)["pr_done"], "the closure is recorded"

      # Every later poll skips the dir before any API call.
      gh2 = pull(pr_obj: pr(state: "closed"))
      assert_empty gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 0, @github.pr_fetches, "a done PR must not cost even the metadata call"
      assert_equal 0, gh2.scanned_count, "a done dir no longer counts as polled"
    end

    def test_clear_pr_done_resumes_polling
      gh = pull(pr_obj: pr(state: "closed"))
      capture_io { gh.poll_intents("2000-01-01T00:00:00Z") }

      gh.clear_pr_done("42", "openproject")
      gh2 = pull   # open PR again (the default)
      gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.pr_fetches, "a cleared flag puts the PR back in the poll set"
    end

    def test_ignores_comments_without_mention
      gh = pull(issue: [issue_c(id: 1, body: "looks good to me", login: "thykel", at: "2026-06-18T18:05:00Z")])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    def test_mentioning_the_bots_github_login_triggers
      gh = pull(issue: [issue_c(id: 1, body: "@chomper-bot please guard nil", login: "thykel", at: "2026-06-18T18:05:00Z")])
      assert_equal 1, gh.poll_intents("2000-01-01T00:00:00Z").length
    end

    def test_refresh_comment_carries_the_refresh_command
      gh = pull(issue: [issue_c(id: 1, body: "@chomper refresh", login: "thykel", at: "2026-06-18T18:05:00Z")])
      assert_equal :refresh, gh.poll_intents("2000-01-01T00:00:00Z").first.command
    end

    def test_refresh_command_works_with_the_bots_login_too
      gh = pull(issue: [issue_c(id: 1, body: "@chomper-bot refresh please", login: "thykel", at: "2026-06-18T18:05:00Z")])
      assert_equal :refresh, gh.poll_intents("2000-01-01T00:00:00Z").first.command
    end

    def test_ordinary_comments_carry_no_command
      gh = pull(issue: [issue_c(id: 1, body: "@chomper refreshing take — please guard nil",
                                login: "thykel", at: "2026-06-18T18:05:00Z")])
      assert_nil gh.poll_intents("2000-01-01T00:00:00Z").first.command,
                 "\"refreshing\" must not word-boundary-match the refresh command"
    end

    def test_allowlist_rejects_other_users_and_advances_cutoff
      gh = pull(issue: [issue_c(id: 9, body: "@chomper do it", login: "rando", at: "2026-06-18T18:05:00Z")])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
      state = JSON.parse((@pr_dir / "gh_pr.json").read)
      assert_equal "2026-06-18T18:05:00Z", state["last_acted_comment_at"]
    end

    def test_scan_from_floor_excludes_older_comments
      gh = pull(issue: [issue_c(id: 1, body: "@chomper old one", login: "thykel", at: "2024-01-01T00:00:00Z")])
      assert_empty gh.poll_intents("2024-06-01T00:00:00Z")
    end

    def test_skips_chompers_own_recorded_replies
      gh = pull(issue: [issue_c(id: 1, body: "@chomper hi", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.record_chomper_comment("42", "openproject", 1)
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    # ── content cache ────────────────────────────────────────────────────────

    def test_caches_full_pr_content_including_copilot_review
      gh = pull(
        issue:   [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
        review:  [review_c(id: 2, body: "This nil isn't guarded.", login: "copilot-pull-request-reviewer[bot]",
                           at: "2026-06-18T17:00:00Z", path: "app/x.rb", line: 9, diff_hunk: "@@ -1 +1 @@")],
        reviews: [review_summary(id: 3, body: "A few issues to address.", login: "copilot-pull-request-reviewer[bot]",
                                 state: "COMMENTED", at: "2026-06-18T17:00:00Z")]
      )
      gh.poll_intents("2000-01-01T00:00:00Z")

      cache = JSON.parse((@pr_dir / "pr.json").read)
      assert_equal "bug/42-fix-the-bug", cache["head_ref"]
      assert(cache["comments"].any? { |c| c["author"].include?("copilot") && c["diff_hunk"] },
             "Copilot's inline finding should be cached with its diff hunk")
      assert(cache["reviews"].any? { |r| r["author"].include?("copilot") && r["body"].include?("issues") },
             "Copilot's review summary should be cached")
    end

    def test_reuses_cache_while_pr_updated_at_is_unchanged
      # First poll fetches comments and writes pr.json.
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.comment_fetches

      # Second poll, same PR updated_at but a NEW comment available: the cache is
      # reused, so the comment streams are NOT re-fetched and nothing new surfaces.
      gh2 = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z"),
                         issue_c(id: 2, body: "@chomper again", login: "thykel", at: "2026-06-18T18:06:00Z")])
      gh2.record_chomper_comment("42", "openproject", 1)            # id 1 already handled
      intents = gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 0, @github.comment_fetches, "unchanged updated_at must reuse pr.json, not re-fetch"
      assert_empty intents
    end

    def test_refetches_when_pr_updated_at_changes
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.poll_intents("2000-01-01T00:00:00Z")

      gh2 = pull(issue: [issue_c(id: 2, body: "@chomper again", login: "thykel", at: "2026-06-18T18:30:00Z")],
                 pr_obj: pr(updated_at: "2026-06-18T18:30:00Z"))
      gh2.record_chomper_comment("42", "openproject", 1)
      intents = gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.comment_fetches, "a changed updated_at must re-fetch the comment streams"
      assert_equal [2], intents.map(&:comment_id)
    end

    def test_mark_acted_advances_to_the_latest
      gh = pull
      gh.mark_acted("42", "openproject", "2026-06-18T18:00:00Z")
      gh.mark_acted("42", "openproject", "2024-01-01T00:00:00Z") # older — must not regress
      state = JSON.parse((@pr_dir / "gh_pr.json").read)
      assert_equal "2026-06-18T18:00:00Z", state["last_acted_comment_at"]
    end

    # ── CI auto-fix ──────────────────────────────────────────────────────────

    def test_no_ci_intent_while_checks_are_still_running
      gh = pull(check_runs: [check_run(status: "in_progress", conclusion: nil)])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    def test_acts_on_the_first_failure_without_waiting_for_pending_checks
      gh = pull(check_runs: [
        check_run(name: "yamllint", conclusion: "failure"),         # fast job already failed
        check_run(name: "RSpec", status: "in_progress", conclusion: nil)  # slow job still running
      ])
      intents = gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal [:ci], intents.map(&:kind), "a completed failure fires now, not after the slow job finishes"
    end

    def test_no_ci_intent_when_all_checks_are_green
      gh = pull(check_runs: [check_run(conclusion: "success")])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    def test_green_verdict_is_cached_for_a_settled_pr_so_check_runs_isnt_re_polled
      # The default PR updated_at is days old → settled, so green is trusted.
      gh = pull(check_runs: [check_run(conclusion: "success")])
      gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.check_runs_calls
      assert_equal "sha123", JSON.parse((@pr_dir / "gh_pr.json").read)["ci_quiet_sha"]

      # Same head SHA next poll → the cached verdict short-circuits before any API call.
      gh2 = pull(check_runs: [check_run(conclusion: "success")])
      gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 0, @github.check_runs_calls, "a green SHA must not be re-checked"
    end

    def test_green_is_not_cached_until_the_commit_settles
      # A just-pushed commit: only the fast green checks have registered so far.
      # Caching green now would hide the failing checks that register seconds later.
      pull(check_runs: [check_run(conclusion: "success")],
           pr_obj: pr(updated_at: Time.now.utc.iso8601)).poll_intents("2000-01-01T00:00:00Z")
      gh2 = pull(check_runs: [check_run(conclusion: "success")],
                 pr_obj: pr(updated_at: Time.now.utc.iso8601))
      gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.check_runs_calls, "a fresh green commit must keep being re-checked, not cached"
    end

    def test_pending_checks_are_not_cached_and_keep_being_polled
      pull(check_runs: [check_run(status: "in_progress", conclusion: nil)]).poll_intents("2000-01-01T00:00:00Z")
      gh2 = pull(check_runs: [check_run(status: "in_progress", conclusion: nil)])
      gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.check_runs_calls, "an unfinished run must keep being polled, not cached"
    end

    def test_failed_checks_yield_one_ci_intent_and_cache_failure_detail
      gh = pull(
        check_runs:    [check_run(annotations_count: 1)],
        annotations:   [Annotation.new(path: "app/x.rb", start_line: 42,
                                       annotation_level: "failure", message: "undefined method")],
        workflow_runs: [WfRun.new(id: 7)],
        jobs:          [WfJob.new(id: 9, name: "RSpec", status: "completed", conclusion: "failure")],
        job_log:       "....\nFAIL app/x.rb:42\n"
      )
      intents = gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, intents.length
      i = intents.first
      assert_equal :ci, i.kind
      assert_equal "sha123", i.head_sha
      assert_equal "bug/42-fix-the-bug", i.branch

      ci = JSON.parse((@pr_dir / "ci.json").read)
      assert_equal "sha123", ci["head_sha"]
      failed = ci["failed"].first
      assert_equal "RSpec", failed["name"]
      assert_equal "app/x.rb", failed["annotations"].first["path"]
      assert_includes failed["log_excerpt"], "FAIL app/x.rb:42"
    end

    def test_ignored_check_names_do_not_trigger_a_ci_fix
      @ctx.ci_ignored_checks = ["saas tests"]
      gh = pull(check_runs: [
        check_run(name: "SaaS tests", conclusion: "failure"),   # ignored → not actionable
        check_run(name: "Yamllint", conclusion: "success")
      ])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z"),
                   "a failure only in an ignored check must not trigger a fix"
    end

    def test_a_real_failure_alongside_an_ignored_one_still_triggers
      @ctx.ci_ignored_checks = ["saas tests"]
      gh = pull(check_runs: [
        check_run(name: "SaaS tests", conclusion: "failure"),
        check_run(name: "Yamllint", conclusion: "failure")
      ])
      intents = gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal [:ci], intents.map(&:kind)
      assert_equal ["Yamllint"], JSON.parse((@pr_dir / "ci.json").read)["failed"].map { |f| f["name"] },
                   "the ignored check is excluded from ci.json too"
    end

    def test_does_not_act_twice_on_the_same_head_sha
      gh = pull(check_runs: [check_run])
      gh.mark_ci_acted("42", "openproject", "sha123")     # already chased this commit
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    def test_gives_up_after_the_attempt_cap_and_posts_once
      @ctx.ci_max_attempts = 2
      gh = pull(check_runs: [check_run])
      # Two prior attempts on earlier commits exhaust the cap.
      gh.mark_ci_acted("42", "openproject", "old1")
      gh.mark_ci_acted("42", "openproject", "old2")

      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.ci_comments.length, "a one-time give-up note is posted"
      assert_includes @github.ci_comments.first[2], "needs a human"

      # A second poll must not post the note again.
      gh2 = pull(check_runs: [check_run])
      assert_empty gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_empty @github.ci_comments, "the give-up note is not re-posted"
    end

    def test_a_comment_trigger_suppresses_the_ci_intent_this_tick
      gh = pull(
        issue:      [issue_c(id: 1, body: "@chomper please tweak", login: "thykel", at: "2026-06-18T18:05:00Z")],
        check_runs: [check_run]
      )
      intents = gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal [:issue], intents.map(&:kind), "the comment wins; CI re-runs on the next commit"
    end

    def test_mark_ci_acted_records_sha_and_increments_attempts
      gh = pull
      gh.mark_ci_acted("42", "openproject", "sha123")
      gh.mark_ci_acted("42", "openproject", "sha456")
      state = JSON.parse((@pr_dir / "gh_pr.json").read)
      assert_equal "sha456", state["ci_acted_sha"]
      assert_equal 2, state["ci_attempts"]
    end

    def test_only_watches_dirs_with_a_shipped_pr
      planned = @ctx.state_dir / "work_packages" / "test.host" / "99"
      planned.mkpath
      (planned / "plan.md").write("## Plan") # no per-repo pr_url.txt → not watched
      gh = pull
      # Each shipped PR dir is <id>/repos/<name>; the WP id is two levels up.
      assert_equal ["42"], gh.shipped_pr_dirs.map { |d| d.parent.parent.basename.to_s }
    end
  end
end
