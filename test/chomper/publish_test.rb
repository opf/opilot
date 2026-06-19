require_relative "../test_helper"

module Chomper
  class PublishTest < Minitest::Test
    # Records what Publish asks the GitHub client to do, so we can assert the
    # branch goes to the fork and the PR is opened against upstream.
    class FakeGitHub
      attr_reader :forked, :pushed, :pr_calls
      def initialize(existing: nil)
        @existing = existing; @forked = []; @pushed = []; @pr_calls = []
      end
      def ensure_fork(upstream); @forked << upstream; "me/openproject"; end
      def find_open_pr(_base_repo, head:); @existing; end
      def push_branch(repo, branch:, worktree_path:); @pushed << [repo, branch]; end
      def create_draft_pr(repo, base:, head:, title:, body:)
        @pr_calls << { repo: repo, base: base, head: head, title: title }
        "https://github.com/opf/openproject/pull/7"
      end
    end

    class FakeRemote
      def url; "git@github.com:opf/openproject.git"; end   # worktree origin = upstream
    end

    class FakeWorktree
      def revparse(_ref); "sha"; end          # branch "exists"
      def remote(_name); FakeRemote.new; end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = Struct.new(:github_token, :worktree_host, :state_dir, :log_file, :progress_file).new(
        "ghtok", Pathname(@tmpdir) / ".chomper" / "openproject", Pathname(@tmpdir) / ".chomper",
        Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt"
      )
      @dir = @ctx.state_dir / "items" / "42"
      @dir.mkpath
      (@dir / "pr.md").write("PR body here")

      @publish = Publish.new(@ctx)
      @github  = FakeGitHub.new
      @publish.instance_variable_set(:@github, @github)
      @publish.instance_variable_set(:@worktree, FakeWorktree.new)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_pushes_to_fork_and_opens_pr_against_upstream
      url = nil
      capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug") }

      assert_equal ["opf/openproject"], @github.forked
      assert_equal [["me/openproject", "bug/42-fix-the-bug"]], @github.pushed,
                   "the branch must be pushed to the fork, never to upstream"
      call = @github.pr_calls.first
      assert_equal "opf/openproject", call[:repo], "the PR is opened against upstream"
      assert_equal "dev", call[:base]
      assert_equal "me:bug/42-fix-the-bug", call[:head], "cross-repo head is fork_owner:branch"
      assert_equal "https://github.com/opf/openproject/pull/7", url
      assert_equal url, (@dir / "pr_url.txt").read
    end

    def test_existing_pr_is_reported_without_pushing
      @github = FakeGitHub.new(existing: "https://github.com/opf/openproject/pull/3")
      @publish.instance_variable_set(:@github, @github)

      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug") }

      assert_empty @github.pushed, "an already-open PR must not be re-pushed"
      assert_empty @github.pr_calls
      assert_equal "https://github.com/opf/openproject/pull/3", (@dir / "pr_url.txt").read
    end
  end
end
