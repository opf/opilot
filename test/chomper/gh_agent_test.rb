require_relative "../test_helper"

module Chomper
  class GhAgentTest < Minitest::Test
    PostedComment = Struct.new(:id, keyword_init: true)

    class FakeClaude
      attr_reader :runs
      def initialize(reply: "Done — guarded the nil case.", boom: false)
        @reply = reply; @boom = boom; @runs = []
      end
      def run(prompt, tools: nil, model: nil, session_file: nil)
        @runs << { prompt: prompt, tools: tools, session_file: session_file }
        raise "claude blew up" if @boom
        @reply
      end
    end

    class FakeGitHub
      attr_reader :issue_posts, :review_posts, :fetched
      def initialize; @issue_posts = []; @review_posts = []; @fetched = []; end
      def fetch_branch(repo, branch:, worktree_path:)
        @fetched << [repo, branch, worktree_path]
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
      def mark_acted(id, at); @acted << [id, at]; end
      def record_chomper_comment(id, cid); @recorded << [id, cid]; end
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
      @tmpdir = Dir.mktmpdir
      @ctx = Struct.new(
        :state_dir, :worktree_container, :state_container, :worktree_host,
        :github_token, :allowed_gh_users, :log_file, :progress_file
      ).new(
        Pathname(@tmpdir) / ".chomper", "/repo", "/state", Pathname(@tmpdir) / ".chomper" / "openproject",
        "ghtok", ["thykel"], Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt"
      )
      (@ctx.state_dir / "items" / "42").mkpath

      @claude  = FakeClaude.new
      @github  = FakeGitHub.new
      @pull    = FakePull.new
      @agent   = GhAgent.new(@ctx, pull: @pull, claude: @claude, github: @github)
      @agent.instance_variable_set(:@worktree, FakeWorktree.new(has_changes: true))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def gh_intent(kind: :issue, text: "@chomper please guard nil", login: "thykel", id: 99)
      GhIntent.new(item_id: "42", subject: "Fix the bug", branch: "bug/42-fix-the-bug",
                   repo: "o/r", head_repo: "fork/r", pr_number: 7, pr_url: "https://github.com/o/r/pull/7",
                   kind: kind, comment_id: id, text: text, user_login: login,
                   comment_at: "2024-02-01T00:00:00Z")
    end

    def test_code_request_posts_reply_commits_and_prints_push_command
      out, = capture_io { @agent.handle(gh_intent) }

      assert_equal 1, @github.issue_posts.length, "reply should be posted to the PR conversation"
      assert_equal "🤖 Done — guarded the nil case.", @github.issue_posts.first[2]
      assert_equal ["[#42] address PR feedback"], @agent.instance_variable_get(:@worktree).commits
      assert_includes out, "git -C #{@ctx.worktree_host} push https://github.com/fork/r.git bug/42-fix-the-bug:bug/42-fix-the-bug"
      assert_equal [["42", 1000]], @pull.recorded, "chomper's own reply id is recorded"
    end

    def test_question_without_changes_replies_but_does_not_commit_or_push
      @agent.instance_variable_set(:@worktree, FakeWorktree.new(has_changes: false))
      out, = capture_io { @agent.handle(gh_intent(text: "@chomper does this handle empty input?")) }

      assert_equal 1, @github.issue_posts.length
      assert_empty @agent.instance_variable_get(:@worktree).commits
      refute_includes out, "git push"
      refute_includes out, "push https://github.com"
    end

    def test_review_comment_reply_lands_in_thread
      @agent.instance_variable_set(:@worktree, FakeWorktree.new(has_changes: false))
      capture_io { @agent.handle(gh_intent(kind: :review, id: 55)) }

      assert_empty @github.issue_posts
      assert_equal 1, @github.review_posts.length
      assert_equal 55, @github.review_posts.first[3], "reply must thread under the inline comment"
    end

    def test_fetches_pr_head_over_https_and_resets_to_it
      capture_io { @agent.handle(gh_intent) }
      assert_equal [["fork/r", "bug/42-fix-the-bug", @ctx.worktree_host]], @github.fetched,
                   "must fetch from the PR's head repo (the fork), not the base repo or the worktree's SSH origin"
      assert_includes @agent.instance_variable_get(:@worktree).resets, "FETCH_HEAD"
    end

    def test_implementation_runs_with_write_tools_and_a_gh_session
      capture_io { @agent.handle(gh_intent) }
      run = @claude.runs.first
      assert_equal Claude::TOOLS_IMPL, run[:tools]
      assert_equal (@ctx.state_dir / "items" / "42" / "gh_session_id"), run[:session_file]
    end

    def test_handle_and_ack_marks_acted_and_reports_on_error
      agent = GhAgent.new(@ctx, pull: @pull, claude: FakeClaude.new(boom: true), github: @github)
      agent.instance_variable_set(:@worktree, FakeWorktree.new(has_changes: false))

      capture_io { agent.handle_and_ack(gh_intent) }

      assert_equal [["42", "2024-02-01T00:00:00Z"]], @pull.acted, "acked despite the error → no replay"
      assert(@github.issue_posts.any? { |p| p[2].include?("hit an error") }, "the failure should be reported on the PR")
    end
  end
end
