require_relative "../test_helper"

module Chomper
  class GhAgentTest < Minitest::Test
    PostedComment = Struct.new(:id, keyword_init: true)

    class FakeClaude
      attr_reader :runs
      def initialize(reply: "Done — guarded the nil case.",
                     subject: "Guard against a nil invoice total", boom: false)
        @reply = reply; @subject = subject; @boom = boom; @runs = []
      end
      def run(prompt, tools: nil, model: nil, session_file: nil)
        @runs << { prompt: prompt, tools: tools, session_file: session_file }
        raise "claude blew up" if @boom
        # The follow-up commit-subject pass uses a distinct prompt.
        prompt.include?("commit subject line") ? @subject : @reply
      end
    end

    class FakeGitHub
      attr_reader :issue_posts, :review_posts, :fetched, :pushed
      def initialize; @issue_posts = []; @review_posts = []; @fetched = []; @pushed = []; end
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
    end

    class FakePull
      attr_reader :acted, :recorded
      def initialize; @acted = []; @recorded = []; end
      def mark_acted(id, repo_name, at); @acted << [id, repo_name, at]; end
      def record_chomper_comment(id, repo_name, cid); @recorded << [id, repo_name, cid]; end
    end

    class FakeCommit
      def sha; "abcdef1234567"; end
      def message; "[#42] address PR feedback"; end
    end

    class FakeLog
      def execute; [FakeCommit.new]; end
    end

    class FakeDiff
      def initialize(has) @has = has end
      def entries; @has ? [:change] : []; end
      def stats; { files: { "app/x.rb" => { insertions: 2, deletions: 1 } } }; end
    end

    class FakeWorktree
      attr_reader :commits, :configs, :fetched, :resets, :checkouts
      def initialize(has_changes: true)
        @has_changes = has_changes
        @commits = []; @configs = []; @fetched = []; @resets = []; @checkouts = []
      end
      def revparse(_ref); "sha"; end
      def fetch(remote, **opts); @fetched << [remote, opts]; end
      def checkout(branch, **_opts); @checkouts << branch; end
      def reset_hard(ref); @resets << ref; end
      def config(key, value); @configs << [key, value]; end
      def add(**_opts); end
      def diff(*_args); FakeDiff.new(@has_changes); end
      def commit(msg); @commits << msg; end
      def log(*_args); FakeLog.new; end
    end

    def setup
      Chomper.reset_stop!   # the stop flag is process-global; isolate each test
      @tmpdir = Dir.mktmpdir
      state_dir = Pathname(@tmpdir) / ".chomper"
      state_dir.mkpath
      registry = Registry.build(script_dir: Pathname(@tmpdir), state_dir: state_dir, op_repo_path: @tmpdir)
      @repo = registry.default   # by_upstream("o/r") falls back to the default repo
      @ctx = Struct.new(
        :state_dir, :state_container,
        :github_token, :allowed_gh_users, :log_file, :progress_file, :repos
      ).new(
        state_dir, "/state",
        # nil token: keeps Helpers.adopt_github_author! (called in commit_followup)
        # a no-op so the suite never makes a real GitHub call; handle() uses the
        # injected @github, not ctx.github_token.
        nil, ["thykel"], Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt", registry
      )
      (@ctx.state_dir / "items" / "42").mkpath

      @claude  = FakeClaude.new
      @github  = FakeGitHub.new
      @pull    = FakePull.new
      @agent   = GhAgent.new(@ctx, pull: @pull, claude: @claude, github: @github)
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
      @ctx.state_dir / "items" / "42" / "repos" / "openproject" / "gh_session_id"
    end

    def gh_intent(kind: :issue, text: "@chomper please guard nil", login: "thykel", id: 99)
      GhIntent.new(item_id: "42", repo_name: "openproject", subject: "Fix the bug", branch: "bug/42-fix-the-bug",
                   repo: "o/r", head_repo: "fork/r", pr_number: 7, pr_url: "https://github.com/o/r/pull/7",
                   kind: kind, comment_id: id, text: text, user_login: login,
                   comment_at: "2024-02-01T00:00:00Z")
    end

    # A reply-only intent for an upstream PR chomper did not open.
    def review_intent(kind: :issue, id: 99, text: "@chomper what do you think?")
      GhIntent.new(item_id: nil, repo_name: "openproject", subject: "Fix a thing",
                   branch: "contrib-branch", repo: "opf/openproject", head_repo: "contributor/openproject",
                   pr_number: 7, pr_url: "https://github.com/opf/openproject/pull/7",
                   kind: kind, comment_id: id, text: text, user_login: "thykel",
                   comment_at: "2026-06-20T09:00:00Z", reply_only: true)
    end

    def test_upstream_reply_only_reviews_without_committing_or_pushing
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          claude: @claude, github: @github)
      inject_worktree(agent, @worktree = FakeWorktree.new(has_changes: true))

      capture_io { agent.handle(review_intent) }

      assert_equal 1, @github.issue_posts.length, "the review reply is posted to the PR conversation"
      assert_empty @worktree.commits, "reply-only must never commit"
      assert_empty @github.pushed,    "reply-only must never push"
      review_run = @claude.runs.find { |r| r[:prompt].include?("you do NOT own") }
      assert_equal Claude::TOOLS_READ, review_run[:tools], "review runs read-only"
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
      assert_equal [["42", "openproject", 1000]], @pull.recorded, "chomper's own reply id is recorded"
    end

    def test_commit_subject_is_generated_in_the_gh_session_and_falls_back
      capture_io { @agent.handle(gh_intent) }
      subject_run = @claude.runs.find { |r| r[:prompt].include?("commit subject line") }
      refute_nil subject_run, "a follow-up pass should generate the commit subject"
      assert_equal gh_session_path, subject_run[:session_file],
                   "the subject is generated in the same session that made the change"

      # When the model returns nothing usable, fall back to the generic subject.
      blank = GhAgent.new(@ctx, pull: @pull, claude: FakeClaude.new(subject: "  "), github: @github)
      @blank_wt = FakeWorktree.new(has_changes: true); inject_worktree(blank, @blank_wt)
      capture_io { blank.handle(gh_intent) }
      assert_equal ["[#42] address PR feedback"], @blank_wt.commits
    end

    def test_question_without_changes_replies_but_does_not_commit_or_push
      inject_worktree(@agent, @worktree = FakeWorktree.new(has_changes: false))
      @agent.handle(gh_intent(text: "@chomper does this handle empty input?"))

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
      run = @claude.runs.first
      assert_equal Claude::TOOLS_IMPL, run[:tools]
      assert_equal gh_session_path, run[:session_file]
    end

    def test_ctrl_c_aborts_quietly_without_posting_or_acking
      agent = GhAgent.new(@ctx, pull: @pull, upstream_pull: UpstreamGhPull.new(@ctx),
                          claude: FakeClaude.new(boom: true), github: @github)
      inject_worktree(agent, FakeWorktree.new(has_changes: false))
      Chomper.request_stop   # simulate Ctrl-C interrupting a child process mid-handle

      capture_io { agent.handle_and_ack(gh_intent) }

      assert_empty @github.issue_posts, "an interrupted handle must not leak an error onto the PR"
      assert_empty @pull.acted, "the comment is left un-acked so the next run retries it"
    ensure
      Chomper.reset_stop!
    end

    def test_handle_and_ack_marks_acted_and_reports_on_error
      agent = GhAgent.new(@ctx, pull: @pull, claude: FakeClaude.new(boom: true), github: @github)
      inject_worktree(agent, FakeWorktree.new(has_changes: false))

      capture_io { agent.handle_and_ack(gh_intent) }

      assert_equal [["42", "openproject", "2024-02-01T00:00:00Z"]], @pull.acted, "acked despite the error → no replay"
      assert(@github.issue_posts.any? { |p| p[2].include?("hit an error") }, "the failure should be reported on the PR")
    end
  end
end
