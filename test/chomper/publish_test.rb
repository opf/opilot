require_relative "../test_helper"

module Chomper
  class PublishTest < Minitest::Test
    # Records what Publish asks the GitHub client to do, so we can assert the
    # branch goes to the fork and the PR is opened against the repo's upstream.
    class FakeGitHub
      attr_reader :forked, :pushed, :pr_calls
      def initialize(existing: nil)
        @existing = existing; @forked = []; @pushed = []; @pr_calls = []
      end
      def ensure_fork(upstream); @forked << upstream; "me/#{upstream.split('/').last}"; end
      def find_open_pr(_base_repo, head:); @existing; end
      def push_branch(repo, branch:, worktree_path:); @pushed << [repo, branch]; end
      def create_draft_pr(repo, base:, head:, title:, body:, maintainer_can_modify: true)
        @pr_calls << { repo: repo, base: base, head: head, title: title, mcm: maintainer_can_modify }
        "https://github.com/#{repo}/pull/7"
      end
    end

    class FakeWorktree
      def revparse(_ref); "sha"; end          # branch "exists"
    end

    CtxStruct = Struct.new(:github_token, :state_dir, :log_file, :progress_file, :pr_mode, :repos) do
      def direct_pr?; pr_mode == "direct"; end
      def default_repo; repos.default; end
    end

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      state   = @tmpdir / ".chomper"
      state.mkpath
      registry = Registry.build(script_dir: @tmpdir, state_dir: state, op_repo_path: "/op")
      @repo = registry.default
      @ctx = CtxStruct.new("ghtok", state, @tmpdir / "chomp.log", @tmpdir / "progress.txt", "fork", registry)

      @dir = state / "items" / "42"
      (@dir / "repos" / @repo.name).mkpath
      (@dir / "repos" / @repo.name / "pr.md").write("PR body here")

      @publish = Publish.new(@ctx)
      @publish.instance_variable_set(:@github, FakeGitHub.new)
      @publish.instance_variable_set(:@worktrees, { @repo.name => FakeWorktree.new })
      @github = @publish.instance_variable_get(:@github)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def pr_url_file
      @dir / "repos" / @repo.name / "pr_url.txt"
    end

    def test_pushes_to_fork_and_opens_pr_against_upstream
      url = nil
      capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      assert_equal ["opf/openproject"], @github.forked
      assert_equal [["me/openproject", "bug/42-fix-the-bug"]], @github.pushed,
                   "the branch must be pushed to the fork, never to upstream"
      call = @github.pr_calls.first
      assert_equal "opf/openproject", call[:repo], "the PR is opened against the repo's upstream"
      assert_equal "dev", call[:base], "base comes from the repo, not a hardcoded dev"
      assert_equal "me:bug/42-fix-the-bug", call[:head], "cross-repo head is fork_owner:branch"
      assert_equal true, call[:mcm], "fork PRs allow maintainer edits"
      assert_equal "https://github.com/opf/openproject/pull/7", url
      assert_equal url, pr_url_file.read
    end

    def test_base_branch_comes_from_the_repo
      ck = Registry.build(
        script_dir: @tmpdir, state_dir: @ctx.state_dir,
        config_path: write_repos("repos" => [{ "name" => "ck", "upstream" => "opf/commonmark-ckeditor-build", "base" => "main" }])
      )["ck"]
      (@dir / "repos" / "ck").mkpath
      (@dir / "repos" / "ck" / "pr.md").write("body")
      @publish.instance_variable_set(:@worktrees, { "ck" => FakeWorktree.new })

      capture_io { @publish.open_pr("42", "Fix", "bug/42-fix", ck) }
      assert_equal "main", @github.pr_calls.first[:base]
      assert_equal "opf/commonmark-ckeditor-build", @github.pr_calls.first[:repo]
    end

    def test_direct_mode_pushes_to_upstream_and_opens_same_repo_pr
      @ctx.pr_mode = "direct"
      url = nil
      capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      assert_empty @github.forked, "direct mode must not fork"
      assert_equal [["opf/openproject", "bug/42-fix-the-bug"]], @github.pushed,
                   "direct mode pushes the branch straight to upstream"
      call = @github.pr_calls.first
      assert_equal "opf/openproject", call[:repo]
      assert_equal "opf:bug/42-fix-the-bug", call[:head], "same-repo head is upstream_owner:branch"
      assert_equal false, call[:mcm], "same-repo PRs must disable maintainer edits (GitHub 422s otherwise)"
    end

    def test_existing_pr_is_reported_without_pushing
      @publish.instance_variable_set(:@github, FakeGitHub.new(existing: "https://github.com/opf/openproject/pull/3"))

      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      github = @publish.instance_variable_get(:@github)
      assert_empty github.pushed, "an already-open PR must not be re-pushed"
      assert_empty github.pr_calls
      assert_equal "https://github.com/opf/openproject/pull/3", pr_url_file.read
    end

    private

    def write_repos(doc)
      path = @tmpdir / "repos2.json"
      path.write(JSON.generate(doc))
      path
    end
  end
end
