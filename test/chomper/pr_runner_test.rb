require_relative "../test_helper"
require "stringio"

module Chomper
  class PrRunnerTest < Minitest::Test
    PostedComment = Struct.new(:id, keyword_init: true)
    FakeHead      = Struct.new(:ref, :sha, :repo, keyword_init: true)
    FakeBase      = Struct.new(:ref, keyword_init: true)
    FakeUser      = Struct.new(:login, keyword_init: true)
    FakeSearchRef = Struct.new(:number, keyword_init: true)
    FakePr        = Struct.new(:state, :updated_at, :html_url, :title, :body, :head, :base,
                               :number, :user, keyword_init: true)
    FakeCheck     = Struct.new(:id, :name, :status, :conclusion, :completed_at, :output, keyword_init: true)
    FakeOutput    = Struct.new(:title, :summary, :text, :annotations_count, keyword_init: true)

    class FakeClaude
      attr_reader :runs
      def initialize(reply: "Fixed the failing spec.", subject: "Guard the nil case")
        @reply = reply; @subject = subject; @runs = []
      end
      def run(prompt, tools: nil, model: nil, session_file: nil)
        @runs << { prompt: prompt, tools: tools, model: model, session_file: session_file }
        prompt.include?("commit subject line") ? @subject : @reply
      end
    end

    class FakeGitHub
      attr_reader :fetched, :pushed, :issue_posts, :searches
      attr_accessor :pr, :checks, :search_results
      def initialize(pr:, checks: [])
        @pr = pr; @checks = checks
        @fetched = []; @pushed = []; @issue_posts = []
        @searches = []; @search_results = []
      end
      def login; "op-chomper"; end
      def search_prs(query, per_page: 50); @searches << query; @search_results; end
      def pull_request(_repo, _number); @pr; end
      def check_runs(_repo, _sha); @checks; end
      def check_run_annotations(_repo, _id); []; end
      def workflow_runs(_repo, _sha); []; end
      def issue_comments(_repo, _number); []; end
      def review_comments(_repo, _number); []; end
      def reviews(_repo, _number); []; end
      def fetch_branch(repo, branch:, worktree_path:); @fetched << [repo, branch, worktree_path]; end
      def push_branch(repo, branch:, worktree_path:); @pushed << [repo, branch, worktree_path]; end
      def add_issue_comment(repo, num, body)
        @issue_posts << [repo, num, body]; PostedComment.new(id: 1000)
      end
    end

    class FakePull
      attr_reader :acted, :recorded, :done, :cleared
      def initialize; @acted = []; @recorded = []; @done = []; @cleared = []; end
      def mark_acted(id, repo_name, at); @acted << [id, repo_name, at]; end
      def record_chomper_comment(id, repo_name, cid); @recorded << [id, repo_name, cid]; end
      def mark_pr_done(id, repo_name); @done << [id, repo_name]; end
      def clear_pr_done(id, repo_name); @cleared << [id, repo_name]; end
    end

    class FakeOpPull
      attr_reader :fetched
      attr_accessor :item
      def initialize(item: nil); @item = item; @fetched = []; end
      def fetch_single_item(id); @fetched << id; @item; end
    end

    class FakeCommit
      attr_reader :date
      def initialize(date: Time.utc(2026, 1, 1)); @date = date; end
      def sha; "abcdef1234567"; end
      def message; "[#42] Guard the nil case"; end
    end

    class FakeLog
      def initialize(commits) @commits = commits end
      def between(_from, _to); self; end
      def execute; @commits; end
    end

    class FakeDiff
      def initialize(has) @has = has end
      def entries; @has ? [:change] : []; end
      def stats; { files: { "app/x.rb" => { insertions: 2, deletions: 1 } } }; end
      def patch; "diff --git a/app/x.rb b/app/x.rb\n+  return if total.nil?\n"; end
    end

    class FakeWorktree
      attr_reader :commits, :merges, :fetched, :resets, :checkouts
      attr_accessor :behind, :has_changes, :merge_conflicts, :head_committed_at
      def initialize(behind: false, has_changes: false, merge_conflicts: false)
        @behind = behind; @has_changes = has_changes; @merge_conflicts = merge_conflicts
        @head_committed_at = Time.utc(2026, 1, 1)   # old by default → branch counts as quiet
        @head = "origsha"
        @commits = []; @merges = []; @fetched = []; @resets = []; @checkouts = []
      end
      def revparse(ref); ref == "HEAD" ? @head : "sha"; end
      def fetch(remote, **opts); @fetched << [remote, opts]; end
      def checkout(branch, **_opts); @checkouts << branch; end
      def reset_hard(ref); @resets << ref; @head = ref unless ref == "FETCH_HEAD"; end
      def config(key, value); end
      def add(**_opts); end
      def diff(*_args); FakeDiff.new(@has_changes); end
      # Argless log is the behind-base check (log.between…); log(1) is the
      # just-made commit lookup after commit_refresh.
      def log(n = nil); FakeLog.new(n || @behind ? [FakeCommit.new(date: @head_committed_at)] : []); end
      def merge(_branch, _message)
        @merges << _message
        raise Git::Error, "merge conflict" if @merge_conflicts
        @head = "mergesha"
      end
      def commit(msg); @commits << msg; @head = "commitsha"; end
    end

    UPDATED_AT = Time.utc(2026, 1, 1)

    def setup
      @tmpdir = Dir.mktmpdir
      state_dir = Pathname(@tmpdir) / ".chomper"
      state_dir.mkpath
      registry = Registry.build(script_dir: Pathname(@tmpdir), state_dir: state_dir, op_repo_path: @tmpdir)
      @repo = registry.default
      @ctx = Struct.new(
        :state_dir, :state_container, :github_token, :op_url, :log_file, :progress_file, :repos,
        :auto_approve, :ignored_checks, :pr_mode
      ) do
        def op_host; "test.host"; end
        def auto_plan_approval?; auto_approve; end
        def ci_ignored_checks; ignored_checks; end
        def direct_pr?; pr_mode == "direct"; end
      end.new(
        state_dir, "/state", "gh-token", "https://test.host", Pathname(@tmpdir) / "chomp.log",
        Pathname(@tmpdir) / "progress.txt", registry, true, ["saas tests"], "fork"
      )
      # Keep adopt_github_author! a no-op so the suite never calls the real API.
      Helpers.instance_variable_set(:@github_author_adopted, true)

      @pr_dir = @ctx.state_dir / "work_packages" / "test.host" / "42" / "repos" / "openproject"
      @pr_dir.mkpath
      (@pr_dir / "pr_url.txt").write("https://github.com/opf/openproject/pull/7")
      seed_pr_cache

      @claude  = FakeClaude.new
      @pull    = FakePull.new
      @op_pull = FakeOpPull.new(item: { "id" => "42" })
      @github  = FakeGitHub.new(pr: open_pr)
      @runner  = PrRunner.new(@ctx, claude: @claude, github: @github, gh_pull: @pull, op_pull: @op_pull)
      @worktree = FakeWorktree.new
      inject_worktree(@runner, @worktree)
    end

    def teardown
      Helpers.instance_variable_set(:@github_author_adopted, nil)
      FileUtils.rm_rf(@tmpdir)
    end

    def inject_worktree(runner, wt)
      runner.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })
    end

    def open_pr(state: "open", number: 7, body: "", updated_at: UPDATED_AT, author: "op-chomper")
      FakePr.new(
        state: state, updated_at: updated_at, title: "Fix the bug", body: body,
        number: number, user: FakeUser.new(login: author),
        html_url: "https://github.com/opf/openproject/pull/#{number}",
        head: FakeHead.new(ref: "bug/42-fix", sha: "headsha", repo: nil),
        base: FakeBase.new(ref: "dev")
      )
    end

    # Pre-seed pr.json so fetch_pr_content reuses the cache (updated_at matches)
    # instead of re-fetching comment streams the fake doesn't serve.
    def seed_pr_cache(comments: [], updated_at: UPDATED_AT)
      Helpers.write_json_atomic(@pr_dir / "pr.json", {
        "number" => 7, "repo" => "opf/openproject", "title" => "Fix the bug",
        "state" => "open", "updated_at" => updated_at.utc.iso8601,
        "head_ref" => "bug/42-fix", "head_sha" => "headsha",
        "head_repo" => "op-chomper/openproject",
        "comments" => comments, "reviews" => []
      }, "pr")
    end

    # Make the PR look just-pushed: updated_at within the last day AND a head
    # commit from the last day (commit recency is what gates the base merge).
    def make_pr_fresh(comments: [])
      now = Time.now.utc
      @github.pr = open_pr(updated_at: now)
      seed_pr_cache(comments: comments, updated_at: now)
      @worktree.head_committed_at = now
    end

    # A failed check that completed recently (detail still within retention).
    # Pass an old completed_at to model a failure whose logs have aged out.
    def failing_check(completed_at: Time.now - 3600)
      FakeCheck.new(id: 9, name: "rspec", status: "completed", conclusion: "failure",
                    completed_at: completed_at,
                    output: FakeOutput.new(title: "rspec", summary: "3 examples failed", text: nil,
                                           annotations_count: 0))
    end

    def feedback_comment(at: "2026-01-01T10:00:00Z", author: "reviewer", id: 5)
      { "id" => id, "kind" => "issue", "author" => author, "created_at" => at,
        "body" => "please guard the nil case", "in_reply_to" => nil }
    end

    def test_requires_a_github_token
      @ctx.github_token = nil
      assert_raises(FatalError) { @runner.run("42") }
    end

    def test_reports_when_the_wp_has_no_shipped_pr
      out, = capture_io { @runner.run("77") }
      assert_includes out, "no shipped PR found"
      assert_empty @github.fetched
    end

    def test_skips_a_merged_pr
      @github.pr = open_pr(state: "merged")
      out, = capture_io { @runner.run("42") }
      assert_includes out, "is merged"
      assert_empty @github.fetched, "a non-open PR must not be fetched or touched"
      assert_equal [["42", "openproject"]], @pull.done,
                   "the closure is recorded so gh-agent stops polling the dir too"
    end

    def test_fresh_pr_is_a_noop
      out, = capture_io { @runner.run("42") }
      assert_includes out, "already fresh"
      assert_empty @claude.runs, "nothing to do → no Claude spend"
      assert_empty @github.pushed
      assert_empty @github.issue_posts
      assert_equal [["42", "openproject"]], @pull.cleared,
                   "an open PR lifts any pr_done left by an earlier closure (reopen support)"
    end

    def test_a_pr_with_commits_within_a_day_is_not_merged_from_base
      make_pr_fresh
      @worktree.behind = true
      out, = capture_io { @runner.run("42") }

      assert_empty @worktree.merges, "an actively moving PR must not get a base merge churned in"
      assert_includes out, "skipping the base merge"
      assert_empty @github.pushed
    end

    def test_a_comment_bumped_pr_with_old_commits_still_gets_the_base_merge
      now = Time.now.utc
      @github.pr = open_pr(updated_at: now)   # a fresh comment bumped updated_at…
      seed_pr_cache(updated_at: now)
      @worktree.behind = true                 # …but the branch itself is old and behind
      capture_io { @runner.run("42") }

      assert_equal ["Merge dev into bug/42-fix"], @worktree.merges,
                   "the quiet window is judged on commit history, not any PR activity"
    end

    def test_a_fresh_prs_ci_failure_is_still_fixed_without_a_base_merge
      make_pr_fresh
      @github.checks = [failing_check]
      @worktree.behind = true
      @worktree.has_changes = true
      capture_io { @runner.run("42") }

      assert_empty @worktree.merges
      assert_includes @claude.runs.first[:prompt], "CI FAILURES",
                      "CI fixing is age-independent — only the base merge is gated on staleness"
      assert_equal 1, @github.pushed.length
    end

    def test_clean_merge_pushes_without_a_claude_pass
      @worktree.behind = true
      capture_io { @runner.run("42") }

      assert_equal ["Merge dev into bug/42-fix"], @worktree.merges
      assert_empty @claude.runs, "a clean base merge needs no Claude pass"
      assert_equal [["op-chomper/openproject", "bug/42-fix", @repo.worktree_host]], @github.pushed,
                   "the merge is pushed to the PR's head repo (the fork)"
      assert_empty @github.issue_posts, "no Claude pass → no PR comment"
    end

    def test_ci_failure_runs_claude_commits_and_pushes
      @github.checks = [failing_check]
      @worktree.has_changes = true
      capture_io { @runner.run("42") }

      run = @claude.runs.first
      assert_includes run[:prompt], "CI FAILURES", "the CI task block is in the prompt"
      assert_equal Claude::TOOLS_IMPL, run[:tools]
      assert_equal @pr_dir / "gh_session_id", run[:session_file], "shares gh-agent's per-PR session"
      assert Helpers.file_has_content?(@pr_dir / "ci.json"), "the failure detail is cached for the prompt"
      assert_equal ["[#42] Guard the nil case"], @worktree.commits
      assert_equal [["op-chomper/openproject", "bug/42-fix", @repo.worktree_host]], @github.pushed
      assert_equal "🤖 Fixed the failing spec.", @github.issue_posts.first[2]
      assert_equal [["42", "openproject", 1000]], @pull.recorded, "chomper's own reply id is recorded"
      assert_empty @pull.acted, "no fresh comments → the comment cutoff is untouched"
    end

    def test_expired_ci_detail_falls_back_to_a_base_sync_and_push
      @github.checks = [failing_check(completed_at: Time.now - (60 * 24 * 3600))]   # failed 60 days ago
      @worktree.behind = true
      out, = capture_io { @runner.run("42") }

      assert_includes out, "log retention"
      assert_empty @claude.runs, "no detail left to act on → no Claude CI pass"
      refute (@pr_dir / "ci.json").exist?, "expired detail is not even fetched"
      assert_equal ["Merge dev into bug/42-fix"], @worktree.merges
      assert_equal 1, @github.pushed.length, "the base sync is pushed so CI re-runs"
    end

    def test_expired_ci_detail_on_an_in_sync_branch_reports_nothing_to_push
      @github.checks = [failing_check(completed_at: Time.now - (60 * 24 * 3600))]
      out, = capture_io { @runner.run("42") }

      assert_includes out, "nothing to push; re-run the failed checks"
      assert_empty @claude.runs
      assert_empty @github.pushed
    end

    def test_a_mix_of_old_and_recent_failures_is_not_expired
      @github.checks = [failing_check(completed_at: Time.now - (60 * 24 * 3600)),
                        failing_check(completed_at: Time.now - 3600)]
      @worktree.has_changes = true
      capture_io { @runner.run("42") }

      assert_includes @claude.runs.first[:prompt], "CI FAILURES",
                      "a recent failure still has detail — the newest failed check decides"
    end

    def test_ignored_checks_do_not_trigger_a_refresh
      @github.checks = [FakeCheck.new(id: 9, name: "SaaS tests", status: "completed",
                                      conclusion: "failure", output: nil)]
      out, = capture_io { @runner.run("42") }
      assert_includes out, "already fresh"
      assert_empty @claude.runs
    end

    def test_fresh_feedback_runs_claude_and_advances_the_cutoff
      seed_pr_cache(comments: [feedback_comment])
      capture_io { @runner.run("42") }

      assert_includes @claude.runs.first[:prompt], "UNADDRESSED FEEDBACK"
      assert_equal [["42", "openproject", "2026-01-01T10:00:00Z"]], @pull.acted,
                   "the cutoff advances so gh-agent doesn't re-handle the same feedback"
      assert_equal 1, @github.issue_posts.length, "Claude's summary is posted on the PR"
      assert_empty @github.pushed, "an answer without code changes pushes nothing"
    end

    def test_bot_and_acted_comments_are_not_feedback
      Helpers.write_json_atomic(@pr_dir / "gh_pr.json",
                                { "last_acted_comment_at" => "2026-01-01T09:00:00Z",
                                  "chomper_comment_ids" => ["6"] }, "gh_pr")
      seed_pr_cache(comments: [
        feedback_comment(at: "2026-01-01T08:00:00Z", id: 4),                     # before the cutoff
        feedback_comment(at: "2026-01-01T10:00:00Z", id: 6),                     # already acted
        feedback_comment(at: "2026-01-01T11:00:00Z", id: 7, author: "op-chomper") # chomper's own
      ])
      out, = capture_io { @runner.run("42") }
      assert_includes out, "already fresh"
      assert_empty @claude.runs
    end

    def test_conflicted_merge_is_resolved_by_claude_and_concluded
      @worktree.behind = true
      @worktree.merge_conflicts = true
      @runner.define_singleton_method(:conflicted_files) { |_repo| ["app/x.rb"] }
      capture_io { @runner.run("42") }

      assert_includes @claude.runs.first[:prompt], "MERGE CONFLICTS"
      assert_includes @claude.runs.first[:prompt], "app/x.rb"
      assert_equal ["Merge dev into bug/42-fix"], @worktree.commits,
                   "the resolved merge is concluded with a merge commit"
      assert_equal 1, @github.pushed.length
    end

    def test_unresolved_conflicts_abort_the_merge
      @worktree.behind = true
      @worktree.merge_conflicts = true
      @runner.define_singleton_method(:conflicted_files) { |_repo| ["app/x.rb"] }
      # A still-conflicted file in the (real) worktree path fails the marker check.
      marker_file = @repo.worktree_host / "app" / "x.rb"
      marker_file.dirname.mkpath
      marker_file.write("<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> origin/dev\n")

      out, = capture_io { @runner.run("42") }

      assert_includes out, "needs a human"
      assert_includes @worktree.resets, "HEAD", "the in-progress merge is aborted"
      assert_empty @github.pushed
      assert_empty @worktree.commits
    end

    def test_wp_refresh_mirrors_the_wp_first
      capture_io { @runner.run("42") }
      assert_equal ["42"], @op_pull.fetched, "the WP mirror is refreshed before the PR is touched"
    end

    def test_a_failed_mirror_does_not_block_the_refresh
      @op_pull.item = nil
      out, = capture_io { @runner.run("42") }
      assert_includes out, "Could not mirror #42"
      assert_includes out, "already fresh", "the refresh still runs on the cached copy"
    end

    def test_pasted_url_resolves_a_tracked_pr
      out, = capture_io { @runner.run("https://github.com/opf/openproject/pull/7/files") }

      assert_equal ["42"], @op_pull.fetched, "the tracked PR's WP is mirrored first"
      assert_includes out, "already fresh", "the refresh runs against the existing #42 state dir"
    end

    def test_pasted_url_adopts_an_untracked_pr_via_the_ticket_link
      @github.pr = open_pr(number: 9, body: "Ticket: https://test.host/work_packages/99\n\nFixes a thing.")
      @op_pull.item = { "id" => "99" }
      out, = capture_io { @runner.run("https://github.com/opf/openproject/pull/9") }

      assert_equal ["99"], @op_pull.fetched, "the linked WP is mirrored the usual way"
      adopted = @ctx.state_dir / "work_packages" / "test.host" / "99" / "repos" / "openproject" / "pr_url.txt"
      assert_equal "https://github.com/opf/openproject/pull/9", adopted.read,
                   "the PR is adopted into the WP's normal state dir"
      assert_includes out, "Adopted opf/openproject#9 as #99"
      assert_includes out, "already fresh", "the normal refresh flow then runs"
    end

    def test_wp_id_with_no_local_state_adopts_the_bots_open_pr_from_github
      @github.pr = open_pr(number: 9, body: "Ticket: https://test.host/work_packages/77\n\nFixes a thing.")
      @github.search_results = [FakeSearchRef.new(number: 9)]
      @op_pull.item = { "id" => "77" }
      out, = capture_io { @runner.run("77") }

      assert_equal ['repo:opf/openproject is:pr is:open author:op-chomper "77" in:body'], @github.searches,
                   "discovery is scoped to the registry upstream and the bot author"
      adopted = @ctx.state_dir / "work_packages" / "test.host" / "77" / "repos" / "openproject" / "pr_url.txt"
      assert_equal "https://github.com/opf/openproject/pull/9", adopted.read,
                   "the discovered PR is adopted into the WP's normal state dir"
      assert_includes out, "Adopted opf/openproject#9 as #77"
      assert_includes out, "already fresh", "the normal refresh flow then runs"
    end

    def test_wp_id_adoption_rejects_a_pr_not_authored_by_the_bot
      @github.pr = open_pr(number: 9, body: "Ticket: https://test.host/work_packages/77\n",
                           author: "someone-else")
      @github.search_results = [FakeSearchRef.new(number: 9)]
      out, = capture_io { @runner.run("77") }

      assert_includes out, "no shipped PR found"
      refute (@ctx.state_dir / "work_packages" / "test.host" / "77" / "repos").exist?,
             "a foreign-authored PR must not be adopted"
      assert_empty @github.fetched, "an unadopted PR is never fetched into a worktree"
    end

    def test_wp_id_adoption_rejects_a_pr_whose_ticket_link_points_elsewhere
      @github.pr = open_pr(number: 9, body: "Ticket: https://test.host/work_packages/99\n")
      @github.search_results = [FakeSearchRef.new(number: 9)]
      out, = capture_io { @runner.run("77") }

      assert_includes out, "no shipped PR found"
      refute (@ctx.state_dir / "work_packages" / "test.host" / "77" / "repos").exist?,
             "a PR for another WP must not be adopted"
    end

    def test_pasted_url_without_a_ticket_link_is_reported
      @github.pr = open_pr(number: 9, body: "Some description without any ticket reference.")
      out, = capture_io { @runner.run("https://github.com/opf/openproject/pull/9") }

      assert_includes out, "no test.host work-package link"
      assert_empty @op_pull.fetched
      assert_empty @github.fetched, "an unplaceable PR is never fetched into a worktree"
    end

    def test_ticket_links_below_the_top_of_the_description_do_not_count
      deep_link = "#{"filler line\n" * 20}Ticket: https://test.host/work_packages/99\n"
      @github.pr = open_pr(number: 9, body: deep_link)
      out, = capture_io { @runner.run("https://github.com/opf/openproject/pull/9") }
      assert_includes out, "no test.host work-package link"
    end

    def test_ticket_links_to_another_instance_do_not_count
      @github.pr = open_pr(number: 9, body: "Ticket: https://other.host/work_packages/99\n")
      out, = capture_io { @runner.run("https://github.com/opf/openproject/pull/9") }
      assert_includes out, "no test.host work-package link"
    end

    def test_pasted_url_for_an_unregistered_repo_is_reported
      out, = capture_io { @runner.run("https://github.com/foo/bar/pull/3") }
      assert_includes out, "not in repos.json"
      assert_empty @github.fetched
      assert_empty @op_pull.fetched
    end

    # ── gh-agent's "@chomper refresh" entry point ────────────────────────────

    def test_refresh_one_forces_the_base_merge_on_an_active_pr
      make_pr_fresh   # the branch has fresh commits, which would normally skip the merge
      @worktree.behind = true
      capture_io { @runner.refresh_one("42", "openproject") }

      assert_equal ["Merge dev into bug/42-fix"], @worktree.merges,
                   "an explicit refresh request overrides the quiet-day heuristic"
      assert_equal 1, @github.pushed.length
    end

    def test_refresh_one_raises_for_a_wp_without_a_shipped_pr
      e = assert_raises(RuntimeError) { @runner.refresh_one("77", "openproject") }
      assert_includes e.message, "no shipped PR recorded"
    end

    def test_non_interactive_refresh_pushes_to_the_fork_without_prompting
      runner = PrRunner.new(@ctx, claude: @claude, github: @github, gh_pull: @pull,
                            op_pull: @op_pull, interactive: false)
      inject_worktree(runner, @worktree)
      @ctx.auto_approve = false   # would prompt in interactive mode
      @worktree.behind = true

      out, = with_stdin("") { capture_io { runner.refresh_one("42", "openproject") } }

      refute_includes out, "[y]es push", "a gh-agent-triggered refresh must not block on a terminal prompt"
      assert_equal 1, @github.pushed.length, "fork-mode pushes go straight through, as gh-agent's do"
    end

    def test_non_interactive_refresh_in_direct_mode_declines_without_a_tty
      @ctx.pr_mode = "direct"
      runner = PrRunner.new(@ctx, claude: @claude, github: @github, gh_pull: @pull,
                            op_pull: @op_pull, interactive: false)
      inject_worktree(runner, @worktree)
      @worktree.behind = true

      out, = with_stdin("") { capture_io { runner.refresh_one("42", "openproject") } }

      assert_empty @github.pushed, "a direct-mode push must never happen unconfirmed"
      assert_includes @worktree.resets, "origsha", "the declined refresh is discarded"
      assert_includes out, "discarded"
    end

    def test_direct_mode_prompts_even_with_auto_approval
      @ctx.pr_mode = "direct"   # auto_approve stays true
      @worktree.behind = true
      out, = with_stdin("y\n") { capture_io { @runner.run("42") } }

      assert_includes out, "[y]es push", "direct mode must not silently auto-push"
      assert_equal 1, @github.pushed.length
    end

    def test_discard_resets_the_branch_and_acks_nothing
      @ctx.auto_approve = false
      seed_pr_cache(comments: [feedback_comment])
      @worktree.has_changes = true
      with_stdin("d\n") { capture_io { @runner.run("42") } }

      assert_includes @worktree.resets, "origsha", "the branch is reset to the fetched PR head"
      assert_empty @github.pushed
      assert_empty @github.issue_posts, "a discarded refresh posts no PR comment"
      assert_empty @pull.acted, "a discarded refresh leaves the feedback for a re-run"
    end

    def with_stdin(input)
      old = $stdin
      $stdin = StringIO.new(input)
      yield
    ensure
      $stdin = old
    end
  end
end
