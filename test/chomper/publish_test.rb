require_relative "../test_helper"
require "stringio"

module Chomper
  class PublishTest < Minitest::Test
    # Records what Publish asks the GitHub client to do, so we can assert the
    # branch goes to the fork and the PR is opened on the fork (contributor) or
    # the upstream (maintainer).
    class FakeGitHub
      attr_reader :forked, :synced, :pushed, :pr_calls, :gist_calls, :body_updates
      def initialize(existing: nil)
        @existing = existing; @forked = []; @synced = []; @pushed = []; @pr_calls = []; @gist_calls = []
        @body_updates = []
      end
      def login; "op-chomper"; end
      def ensure_fork(upstream); @forked << upstream; "me/#{upstream.split('/').last}"; end
      def sync_fork_branch(fork, branch); @synced << [fork, branch]; true; end
      def find_open_pr(_base_repo, head:); @existing; end
      def push_branch(repo, branch:, worktree_path:); @pushed << [repo, branch]; end
      def create_gist(description:, filename:, content:, public: false)
        @gist_calls << { description: description, filename: filename, content: content, public: public }
        "https://gist.github.com/me/abc"
      end
      def create_draft_pr(repo, base:, head:, title:, body:, maintainer_can_modify: true)
        @pr_calls << { repo: repo, base: base, head: head, title: title, body: body, mcm: maintainer_can_modify }
        "https://github.com/#{repo}/pull/7"
      end
      def update_pr_body(repo, number, body); @body_updates << { repo: repo, number: number, body: body }; end
    end

    class FakeWorktree
      def revparse(_ref); "sha"; end          # branch "exists"
    end

    CtxStruct = Struct.new(:contributor_token, :maintainer_token, :state_dir, :log_file, :progress_file, :repos) do
      def default_repo; repos.default; end
      def op_host; "test.host"; end   # WP mirror namespace
    end

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      state   = @tmpdir / ".chomper"
      state.mkpath
      registry = Registry.build(script_dir: @tmpdir, state_dir: state, op_repo_path: "/op")
      @repo = registry.default
      @ctx = CtxStruct.new("bot-tok", "maint-tok", state, @tmpdir / "chomp.log", @tmpdir / "progress.txt", registry)

      @dir = state / "work_packages" / "test.host" / "42"
      (@dir / "repos" / @repo.name).mkpath
      (@dir / "repos" / @repo.name / "pr.md").write("PR body here")

      @publish = build_publish   # contributor (fork) by default
      @github  = @publish.instance_variable_get(:@github)
    end

    def build_publish(as: :contributor)
      publish = Publish.new(@ctx, as: as)
      publish.instance_variable_set(:@github, FakeGitHub.new)
      publish.instance_variable_set(:@worktrees, { @repo.name => FakeWorktree.new })
      publish
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def pr_url_file
      @dir / "repos" / @repo.name / "pr_url.txt"
    end

    def test_pushes_to_fork_and_opens_pr_on_the_fork
      url = nil
      capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      assert_equal ["opf/openproject"], @github.forked
      assert_equal [["me/openproject", "dev"]], @github.synced,
                   "the fork's base branch is synced with upstream before the PR is opened"
      assert_equal [["me/openproject", "bug/42-fix-the-bug"]], @github.pushed,
                   "the branch must be pushed to the fork, never to upstream"
      call = @github.pr_calls.first
      assert_equal "me/openproject", call[:repo],
                   "the PR is opened on the fork, keeping it off the upstream queue"
      assert_equal "dev", call[:base], "base comes from the repo, not a hardcoded dev"
      assert_equal "me:bug/42-fix-the-bug", call[:head], "head is fork_owner:branch"
      assert_equal false, call[:mcm], "a same-repo (fork) PR must disable maintainer edits (GitHub 422s otherwise)"
      assert_equal "https://github.com/me/openproject/pull/7", url
      assert_equal url, pr_url_file.read
    end

    def test_fork_pr_gets_the_overtake_note_pointing_at_its_url
      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      refute_includes @github.pr_calls.first[:body], "gh overtake",
                      "the note needs the PR URL, which doesn't exist at create time"
      update = @github.body_updates.first
      refute_nil update, "the body is patched right after creation"
      assert_equal "me/openproject", update[:repo], "the note is patched onto the fork PR"
      assert_equal 7, update[:number]
      assert_includes update[:body],
                      "[run](https://github.com/opf/openproject-chomper#taking-over-a-chomper-pr) " \
                      "`gh overtake https://github.com/me/openproject/pull/7`",
                      "the note links the setup doc and passes this PR's URL (not a bare number)"
      assert update[:body].lines[1].include?("gh overtake"),
             "the note sits at the top, right under the banner"
      assert_includes update[:body], "PR body here", "the rest of the description is untouched"
    end

    def test_maintainer_pr_gets_no_overtake_note
      @publish = build_publish(as: :maintainer)
      @github  = @publish.instance_variable_get(:@github)
      with_stdin("y\n") { capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) } }

      assert_empty @github.body_updates, "a same-repo PR has no fork-CI limitation to note"
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
      assert_equal "me/commonmark-ckeditor-build", @github.pr_calls.first[:repo],
                   "the PR opens on this repo's fork"
      assert_equal [["me/commonmark-ckeditor-build", "main"]], @github.synced
    end

    def test_uses_the_per_wp_base_override_when_present
      (@dir / "target_base.json").write(JSON.generate("openproject" => "release/17.6"))

      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      assert_equal "release/17.6", @github.pr_calls.first[:base],
                   "the PR targets the per-WP base override, not the repo default"
    end

    def test_maintainer_pushes_to_upstream_and_opens_same_repo_pr
      @publish = build_publish(as: :maintainer)
      @github  = @publish.instance_variable_get(:@github)
      url = nil
      out, = with_stdin("y\n") { capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) } }

      assert_includes out, "Push bug/42-fix-the-bug to opf/openproject?",
                      "a canonical push must be gated on an interactive yes"
      assert_empty @github.forked, "the maintainer identity must not fork"
      assert_equal [["opf/openproject", "bug/42-fix-the-bug"]], @github.pushed,
                   "the maintainer pushes the branch straight to upstream"
      call = @github.pr_calls.first
      assert_equal "opf/openproject", call[:repo]
      assert_equal "opf:bug/42-fix-the-bug", call[:head], "same-repo head is upstream_owner:branch"
      assert_equal false, call[:mcm], "same-repo PRs must disable maintainer edits (GitHub 422s otherwise)"
    end

    def test_maintainer_declined_push_opens_no_pr
      @publish = build_publish(as: :maintainer)
      @github  = @publish.instance_variable_get(:@github)
      url = :unset
      out, = with_stdin("s\n") { capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) } }

      assert_nil url
      assert_empty @github.pushed, "a declined canonical push must not reach the remote"
      assert_empty @github.pr_calls, "no push → no PR"
      refute pr_url_file.exist?
      assert_includes out, "Push declined"
    end

    def test_maintainer_with_non_interactive_stdin_declines_the_push
      @publish = build_publish(as: :maintainer)
      @github  = @publish.instance_variable_get(:@github)
      url = :unset
      with_stdin("") { capture_io { url = @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) } }

      assert_nil url, "an unattended canonical push must never happen unconfirmed"
      assert_empty @github.pushed
    end

    def test_missing_identity_token_opens_no_pr
      @ctx.contributor_token = nil
      out, = capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }
      assert_includes out, "GITHUB_CONTRIBUTOR_TOKEN is not set"
      assert_empty @github.pushed
    end

    def with_stdin(text)
      old = $stdin
      $stdin = StringIO.new(text)
      yield
    ensure
      $stdin = old
    end

    def test_existing_pr_is_reported_without_pushing
      @publish.instance_variable_set(:@github, FakeGitHub.new(existing: "https://github.com/opf/openproject/pull/3"))

      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      github = @publish.instance_variable_get(:@github)
      assert_empty github.pushed, "an already-open PR must not be re-pushed"
      assert_empty github.pr_calls
      assert_equal "https://github.com/opf/openproject/pull/3", pr_url_file.read
    end

    def test_plan_is_uploaded_as_a_secret_gist_and_linked_from_the_pr
      (@dir / "plan.md").write("## Plan\nDo the thing.")

      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      gist = @github.gist_calls.first
      refute_nil gist, "the plan should be uploaded as a gist"
      assert_equal false, gist[:public], "the plan gist must be secret"
      assert_equal "wp-42-plan.md", gist[:filename]
      assert_includes gist[:content], "Do the thing."

      body = @github.pr_calls.first[:body]
      assert_includes body, "📋 **Implementation plan:** https://gist.github.com/me/abc"
      assert_includes body, "PR body here", "the per-repo PR description is still present"

      assert_equal "https://gist.github.com/me/abc",
                   (@dir / "gist_url.txt").read.strip, "the gist URL is cached for reuse"
    end

    def test_no_plan_means_no_gist_and_no_plan_link
      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      assert_empty @github.gist_calls, "with no plan.md there is nothing to gist"
      refute_includes @github.pr_calls.first[:body], "Implementation plan:"
    end

    def test_cached_gist_url_is_reused_without_a_second_upload
      (@dir / "plan.md").write("## Plan")
      (@dir / "gist_url.txt").write("https://gist.github.com/me/cached\n")

      capture_io { @publish.open_pr("42", "Fix the bug", "bug/42-fix-the-bug", @repo) }

      assert_empty @github.gist_calls, "a cached gist URL must not trigger a new upload"
      assert_includes @github.pr_calls.first[:body],
                      "📋 **Implementation plan:** https://gist.github.com/me/cached"
    end

    private

    def write_repos(doc)
      path = @tmpdir / "repos2.json"
      path.write(JSON.generate(doc))
      path
    end
  end
end
