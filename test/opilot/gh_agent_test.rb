require_relative "../test_helper"

module OPilot
  class GhAgentTest < Minitest::Test
    PostedComment = Struct.new(:id, keyword_init: true)

    class FakeHarness
      attr_reader :runs
      attr_writer :reply
      def initialize(reply: "Done — guarded the nil case.",
                     subject: "Guard against a nil invoice total", boom: false)
        @reply = reply; @subject = subject; @boom = boom; @runs = []
      end
      def run(prompt, tools: nil, model: nil, session_file: nil)
        @runs << { prompt: prompt, tools: tools, model: model, session_file: session_file }
        raise "harness blew up" if @boom
        # The follow-up commit-subject pass uses a distinct prompt.
        prompt.include?("commit subject line") ? @subject : @reply
      end
    end

    class FakeGitHub
      attr_reader :issue_posts, :review_posts, :reviews_created, :fetched, :pushed, :closed
      def initialize
        @issue_posts = []; @review_posts = []; @reviews_created = []; @fetched = []; @pushed = []
        @closed = []
      end
      def close_pr(repo, num)
        @closed << [repo, num]
      end
      def fetch_branch(repo, branch:, worktree_path:)
        @fetched << [repo, branch, worktree_path]
      end
      def push_branch(repo, branch:, worktree_path:)
        @pushed << [repo, branch, worktree_path]
      end
      def add_issue_comment(repo, num, body)
        @issue_posts << [repo, num, body]; PostedComment.new(id: 1000)
      end
      def reply_to_review_comment(repo, num, body, in_reply_to)
        @review_posts << [repo, num, body, in_reply_to]; PostedComment.new(id: 1001)
      end
      def create_review(repo, num, commit_id:, body:, comments:)
        @reviews_created << { repo: repo, number: num, commit_id: commit_id, body: body, comments: comments }
        PostedComment.new(id: 2000)
      end
    end

    class FakePull
      attr_reader :acted, :recorded, :ci_acted
      def initialize; @acted = []; @recorded = []; @ci_acted = []; end
      def mark_acted(id, repo_name, at, spec: false); @acted << [id, repo_name, at]; end
      def record_opilot_comment(id, repo_name, cid, spec: false); @recorded << [id, repo_name, cid]; end
      def mark_ci_acted(id, repo_name, sha); @ci_acted << [id, repo_name, sha]; end
    end

    class FakePrRunner
      attr_reader :refreshed
      def initialize; @refreshed = []; end
      def refresh_one(wp_id, repo_name); @refreshed << [wp_id, repo_name]; end
    end

    # Shared git doubles (test/support/fixtures.rb), aliased so the nested
    # FakeWorktree below resolves them lexically.
    FakeCommit = TestFixtures::FakeCommit
    FakeLog    = TestFixtures::FakeLog
    FakeDiff   = TestFixtures::FakeDiff

    class FakeWorktree
      attr_reader :commits, :configs, :fetched, :resets, :checkouts
      def initialize(has_changes: true)
        @has_changes = has_changes
        @commits = []; @configs = []; @fetched = []; @resets = []; @checkouts = []
      end
      def revparse(_ref); "sha"; end
      def fetch(remote, **opts); @fetched << [remote, opts]; end
      def checkout(branch, **_opts); @checkouts << branch; end
      def reset(ref, **_opts); @resets << ref; end
      def config_set(key, value); @configs << [key, value]; end
      def add(**_opts); end
      def diff(*_args); FakeDiff.new(@has_changes); end
      def commit(msg); @commits << msg; end
      def log(*_args); FakeLog.new([FakeCommit.new]); end
    end

    include TestFixtures

    def setup
      @tmpdir = Dir.mktmpdir
      # contributor_token stays nil: it keeps Helpers.adopt_github_author!
      # (called in commit_followup) a no-op so the suite never makes a real
      # GitHub call; handle() uses the injected @github, not a ctx token.
      @ctx  = build_ctx(@tmpdir, host: "test.host", allowed_gh_users: ["thykel"])
      @repo = @ctx.repos.default   # by_upstream("o/r") falls back to the default repo
      (@ctx.state_dir / "work_packages" / "test.host" / "42").mkpath

      @harness  = FakeHarness.new
      @github  = FakeGitHub.new
      @pull    = FakePull.new
      @agent   = GhAgent.new(@ctx, pull: @pull, harness: @harness, github: @github)
      @worktree = FakeWorktree.new(has_changes: true)
      inject_worktree(@agent, @worktree)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    # Make worktree(repo) return one fake handle for any repo, so tests drive and
    # inspect a single worktree.
    def inject_worktree(agent, wt)
      agent.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })
    end

    def gh_session_path
      @ctx.state_dir / "work_packages" / "test.host" / "42" / "repos" / "openproject" / "gh_session_id"
    end

    def gh_intent(kind: :issue, text: "@opilot please guard nil", login: "thykel", id: 99)
      GhIntent.new(item_id: "42", repo_name: "openproject", subject: "Fix the bug", branch: "bug/42-fix-the-bug",
                   repo: "o/r", head_repo: "fork/r", pr_number: 7, pr_url: "https://github.com/o/r/pull/7",
                   kind: kind, comment_id: id, text: text, user_login: login,
                   comment_at: "2024-02-01T00:00:00Z")
    end

    # A reply-only intent for an upstream PR opilot did not open.
    def review_intent(kind: :issue, id: 99, text: "@opilot what do you think?", head_sha: nil)
      GhIntent.new(item_id: nil, repo_name: "openproject", subject: "Fix a thing",
                   branch: "contrib-branch", repo: "opf/openproject", head_repo: "contributor/openproject",
                   pr_number: 7, pr_url: "https://github.com/opf/openproject/pull/7",
                   kind: kind, comment_id: id, text: text, user_login: "thykel",
                   comment_at: "2026-06-20T09:00:00Z", reply_only: true, head_sha: head_sha)
    end

    def write_review_ci_json(head_sha)
      dir = @ctx.state_dir / "pr_reviews" / "opf-openproject" / "7"
      dir.mkpath
      (dir / "ci.json").write(JSON.generate("head_sha" => head_sha, "failed" => [{ "name" => "rspec" }]))
    end

    # A CI-failure intent for one of opilot's own PRs (the auto-fix path).
    def ci_intent
      GhIntent.new(item_id: "42", repo_name: "openproject", subject: "Fix the bug", branch: "bug/42-fix-the-bug",
                   repo: "o/r", head_repo: "fork/r", pr_number: 7, pr_url: "https://github.com/o/r/pull/7",
                   kind: :ci, head_sha: "deadbeefcafe", comment_at: "2024-02-01T00:00:00Z")
    end

    def test_ci_intent_fixes_commits_pushes_and_marks_acted_by_sha
      capture_io { @agent.handle_and_ack(ci_intent) }

      run = @harness.runs.first
      assert_equal Harness::TOOLS_IMPL, run[:tools], "the CI fix runs with write tools"
      assert_includes run[:prompt], "CI failed", "the fix-ci prompt is used"
      assert_equal 1, @github.issue_posts.length, "opilot replies on the PR conversation"
      assert_equal [["fork/r", "bug/42-fix-the-bug", @repo.worktree_host]], @github.pushed,
                   "the fix is pushed to the PR's head repo (the fork)"
      assert_equal [["42", "openproject", "deadbeefcafe"]], @pull.ci_acted,
                   "CI act-state is advanced by head SHA, not comment timestamp"
      assert_empty @pull.acted, "the comment-cutoff ack is not used for a CI intent"
    end

    def test_ci_flaky_reply_pushes_nothing_but_still_marks_the_sha_acted
      inject_worktree(@agent, @worktree = FakeWorktree.new(has_changes: false))
      capture_io { @agent.handle_and_ack(ci_intent) }

      assert_equal 1, @github.issue_posts.length, "opilot still replies (e.g. 'looks flaky')"
      assert_empty @github.pushed, "no code change → nothing pushed"
      assert_equal [["42", "openproject", "deadbeefcafe"]], @pull.ci_acted,
                   "the SHA is still marked acted so it isn't re-evaluated next poll"
    end

    def test_upstream_reply_only_reviews_without_committing_or_pushing
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, @worktree = FakeWorktree.new(has_changes: true))

      capture_io { agent.handle(review_intent) }

      assert_equal 1, @github.issue_posts.length, "the review reply is posted to the PR conversation"
      assert_empty @worktree.commits, "reply-only must never commit"
      assert_empty @github.pushed,    "reply-only must never push"
      review_run = @harness.runs.find { |r| r[:prompt].include?("you do NOT own") }
      assert_equal Harness::TOOLS_READ, review_run[:tools], "review runs read-only"
    end

    def test_upstream_review_includes_failing_ci_when_it_matches_the_head
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, FakeWorktree.new)
      write_review_ci_json("abc123")

      capture_io { agent.handle(review_intent(head_sha: "abc123")) }

      review_run = @harness.runs.find { |r| r[:prompt].include?("you do NOT own") }
      assert_includes review_run[:prompt], "FAILING CI", "the review is handed the CI failure detail"
    end

    def test_upstream_review_ignores_ci_cached_against_a_different_head
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, FakeWorktree.new)
      write_review_ci_json("oldsha")   # a failure from an earlier commit

      capture_io { agent.handle(review_intent(head_sha: "newsha")) }

      review_run = @harness.runs.find { |r| r[:prompt].include?("you do NOT own") }
      refute_includes review_run[:prompt], "FAILING CI", "a stale failure isn't shown as current"
    end

    def test_upstream_review_posts_suggestions_as_an_applicable_review
      @harness.reply = <<~OUT
        A nil-guard is missing here.
        SUGGESTIONS:
        ```json
        [{"path": "app/models/user.rb", "start_line": 10, "line": 12, "suggestion": "  return unless items[0]"}]
        ```
        REPLY:
        Suggested a nil-guard inline.
      OUT
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, FakeWorktree.new)

      capture_io { agent.handle(review_intent(head_sha: "abc123")) }

      review = @github.reviews_created.first
      refute_nil review, "an applicable review is posted"
      assert_equal "abc123", review[:commit_id], "suggestions anchor to the reviewed head SHA"
      c = review[:comments].first
      assert_equal "app/models/user.rb", c[:path]
      assert_equal 12, c[:line]
      assert_equal 10, c[:start_line], "a multi-line range carries start_line"
      assert_equal "RIGHT", c[:side]
      assert_includes c[:body], "```suggestion\n  return unless items[0]\n```",
                      "code with a ] survives parsing intact"
      assert_equal 1, @github.issue_posts.length, "the prose reply is still posted"
      refute_includes @github.issue_posts.first[2], "SUGGESTIONS",
                      "the machine block is stripped from the posted reply"
    end

    def test_upstream_review_without_suggestions_posts_no_review
      @harness.reply = "Just a question — no change needed.\nREPLY:\nLooks fine to me."
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, FakeWorktree.new)

      capture_io { agent.handle(review_intent(head_sha: "abc123")) }

      assert_empty @github.reviews_created, "no suggestions → no review posted"
      assert_equal 1, @github.issue_posts.length, "just the conversational reply"
    end

    def test_upstream_suggestions_need_a_head_sha_to_anchor
      @harness.reply = "SUGGESTIONS:\n```json\n[{\"path\":\"a.rb\",\"line\":3,\"suggestion\":\"x = 1\"}]\n```\nREPLY:\nsee inline"
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, FakeWorktree.new)

      capture_io { agent.handle(review_intent(head_sha: nil)) }

      assert_empty @github.reviews_created, "without a head SHA the suggestions can't be anchored"
      assert_equal 1, @github.issue_posts.length, "the reply still posts"
    end

    def test_code_request_replies_commits_and_pushes_to_fork
      capture_io { @agent.handle(gh_intent) }

      assert_equal 1, @github.issue_posts.length, "reply should be posted to the PR conversation"
      assert_equal "🤖 Done — guarded the nil case.", @github.issue_posts.first[2]
      assert_equal ["[#42] Guard against a nil invoice total"],
                   @worktree.commits,
                   "the commit subject describes the change, not a generic placeholder"
      assert_equal [["fork/r", "bug/42-fix-the-bug", @repo.worktree_host]], @github.pushed,
                   "the commit is pushed to the PR's head repo (the fork) via the bot token"
      assert_equal [["42", "openproject", 1000]], @pull.recorded, "opilot's own reply id is recorded"
    end

    def test_reply_preamble_before_the_marker_is_never_posted
      # A model hitting an obstacle narrates it before "the real reply" — the
      # REPLY: contract keeps that narration off the PR.
      @harness.reply = "I can't retrieve PR #127 — no web access here.\n\n" \
                      "Here's my honest reply for the thread:\n\nREPLY:\nWhat #128 does: wraps toModel."
      inject_worktree(@agent, @worktree = FakeWorktree.new(has_changes: false))
      @agent.handle(gh_intent(text: "@opilot compare this with #127"))

      assert_equal "🤖 What #128 does: wraps toModel.", @github.issue_posts.first[2]
    end

    def test_commit_subject_runs_stateless_on_a_cheap_model_and_falls_back
      capture_io { @agent.handle(gh_intent) }
      subject_run = @harness.runs.find { |r| r[:prompt].include?("commit subject line") }
      refute_nil subject_run, "a follow-up pass should generate the commit subject"
      assert_nil subject_run[:session_file], "the subject is generated statelessly, not in the gh session"
      assert_equal Harness::MODEL_LIGHT, subject_run[:model], "the cheap model crafts the commit subject"
      assert_includes subject_run[:prompt], "return if total.nil?", "the diff is embedded in the prompt"

      # When the model returns nothing usable, fall back to the generic subject.
      blank = GhAgent.new(@ctx, pull: @pull, harness: FakeHarness.new(subject: "  "), github: @github)
      @blank_wt = FakeWorktree.new(has_changes: true); inject_worktree(blank, @blank_wt)
      capture_io { blank.handle(gh_intent) }
      assert_equal ["[#42] address PR feedback"], @blank_wt.commits
    end

    def test_refresh_command_hands_the_pr_to_pr_runner_and_acks_the_trigger
      pr_runner = FakePrRunner.new
      agent = GhAgent.new(@ctx, pull: @pull, harness: @harness, github: @github, pr_runner: pr_runner)

      capture_io { agent.handle_and_ack(gh_intent(text: "@opilot refresh").tap { |i| i.command = :refresh }) }

      assert_equal [["42", "openproject"]], pr_runner.refreshed,
                   "the refresh is delegated to PrRunner's single-PR entry point"
      assert_empty @harness.runs, "gh-agent must not also run its own conversational pass"
      assert_empty @github.issue_posts, "PrRunner posts the summary itself"
      assert_equal [["42", "openproject", "2024-02-01T00:00:00Z"]], @pull.acted,
                   "the trigger comment is acked so it doesn't replay"
    end

    def test_close_command_closes_the_pr_replies_and_acks_the_trigger
      intent = gh_intent(text: "@opilot close").tap { |i| i.command = :close }
      capture_io { @agent.handle_and_ack(intent) }

      assert_equal [["o/r", 7]], @github.closed, "the PR opilot opened is closed unmerged"
      assert_empty @harness.runs, "closing spends no LLM call"
      assert_empty @github.pushed, "nothing is pushed for a close"
      assert_equal 1, @github.issue_posts.length, "the commenter is told the PR is closed"
      assert_includes @github.issue_posts.first.last, "closed this pull request"
      assert_equal [["42", "openproject", "2024-02-01T00:00:00Z"]], @pull.acted,
                   "the trigger comment is acked so it doesn't replay"
    end

    def test_close_is_never_acted_on_for_an_upstream_pr
      # An upstream PR is somebody else's: a "close" there is read as prose and
      # answered in text, exactly like any other reply_only comment.
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          harness: @harness, github: @github)
      inject_worktree(agent, FakeWorktree.new(has_changes: false))

      capture_io { agent.handle(review_intent(text: "@opilot close").tap { |i| i.command = :close }) }

      assert_empty @github.closed, "opilot must not close a PR it did not open"
      review_run = @harness.runs.find { |r| r[:prompt].include?("you do NOT own") }
      refute_nil review_run, "it falls through to the read-only review pass"
      assert_equal Harness::TOOLS_READ, review_run[:tools]
    end

    def test_canonical_head_push_is_refused
      # A PR whose head branch lives on a canonical repo (one a maintainer
      # adopted and re-published) is not opilot's to write to.
      intent = gh_intent
      intent.head_repo = @repo.upstream
      out, = capture_io { @agent.handle(intent) }

      assert_equal 1, @worktree.commits.length, "the commit itself still lands in the clone"
      assert_empty @github.pushed, "a canonical push must never reach the remote"
      assert_includes out, "Refusing to push"
      assert_includes out, "not updated"
    end

    def test_question_without_changes_replies_but_does_not_commit_or_push
      inject_worktree(@agent, @worktree = FakeWorktree.new(has_changes: false))
      @agent.handle(gh_intent(text: "@opilot does this handle empty input?"))

      assert_equal 1, @github.issue_posts.length
      assert_empty @worktree.commits
      assert_empty @github.pushed
    end

    def test_review_comment_reply_lands_in_thread
      inject_worktree(@agent, @worktree = FakeWorktree.new(has_changes: false))
      capture_io { @agent.handle(gh_intent(kind: :review, id: 55)) }

      assert_empty @github.issue_posts
      assert_equal 1, @github.review_posts.length
      assert_equal 55, @github.review_posts.first[3], "reply must thread under the inline comment"
    end

    def test_fetches_pr_head_over_https_and_resets_to_it
      capture_io { @agent.handle(gh_intent) }
      assert_equal [["fork/r", "bug/42-fix-the-bug", @repo.worktree_host]], @github.fetched,
                   "must fetch from the PR's head repo (the fork), not the base repo or the worktree's SSH origin"
      assert_includes @worktree.resets, "FETCH_HEAD"
    end

    def test_implementation_runs_with_write_tools_and_a_gh_session
      capture_io { @agent.handle(gh_intent) }
      run = @harness.runs.first
      assert_equal Harness::TOOLS_IMPL, run[:tools]
      assert_equal gh_session_path, run[:session_file]
    end

    def test_handle_and_ack_marks_acted_and_reports_on_error
      agent = GhAgent.new(@ctx, pull: @pull, harness: FakeHarness.new(boom: true), github: @github)
      inject_worktree(agent, FakeWorktree.new(has_changes: false))

      capture_io { agent.handle_and_ack(gh_intent) }

      assert_equal [["42", "openproject", "2024-02-01T00:00:00Z"]], @pull.acted, "acked despite the error → no replay"
      assert(@github.issue_posts.any? { |p| p[2].include?("could not handle that comment") },
             "the failure should be reported on the PR")
    end
  end
end
