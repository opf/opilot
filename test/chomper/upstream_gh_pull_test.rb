require_relative "../test_helper"

module Chomper
  class UpstreamGhPullTest < Minitest::Test
    User      = Struct.new(:login)
    RepoRef   = Struct.new(:full_name)
    Head      = Struct.new(:ref, :sha, :repo)
    PR        = Struct.new(:state, :updated_at, :html_url, :title, :head, :user, keyword_init: true)
    IssueC    = Struct.new(:id, :body, :user, :created_at, keyword_init: true)
    SearchHit = Struct.new(:number)
    Check     = Struct.new(:id, :name, :status, :conclusion, :output, keyword_init: true)
    Output    = Struct.new(:title, :summary, :text, :annotations_count, keyword_init: true)

    class FakeGitHub
      attr_reader :searches, :reacted, :check_runs_calls
      def initialize(hits: [], issue: [], pr_author: "contributor", checks: [])
        @hits = hits; @issue = issue; @pr_author = pr_author; @checks = checks
        @searches = []; @reacted = []; @check_runs_calls = []
      end
      def search_prs(query, per_page: 50); @searches << query; @hits; end
      def pull_request(_repo, _num)
        PR.new(state: "open", updated_at: Time.parse("2026-06-20T10:00:00Z"),
               html_url: "https://github.com/opf/openproject/pull/7", title: "Fix a thing",
               head: Head.new("contrib-branch", "sha9", RepoRef.new("contributor/openproject")),
               user: User.new(@pr_author))
      end
      def issue_comments(_repo, _num); @issue; end
      def review_comments(_repo, _num); []; end
      def reviews(_repo, _num); []; end
      def react(repo, id, kind:, content: "eyes"); @reacted << [repo, id, kind]; end
      def check_runs(repo, sha); @check_runs_calls << [repo, sha]; @checks; end
      def workflow_runs(_repo, _sha); []; end
      def login; "chomper-bot"; end
    end

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      state   = @tmpdir / ".chomper"
      state.mkpath
      @registry = Registry.build(script_dir: @tmpdir, state_dir: state, op_repo_path: @tmpdir)
      ctx_class = Struct.new(:state_dir, :allowed_gh_users, :contributor_token, :log_file, :repos) do
        def ci_ignored_checks; []; end
      end
      @ctx = ctx_class.new(state, ["thykel"], "ghtok", @tmpdir / "chomp.log", @registry)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def issue_c(id:, body:, login:, at:)
      IssueC.new(id: id, body: body, user: User.new(login), created_at: Time.parse(at))
    end

    def pull(hits: [SearchHit.new(7)], issue: [], pr_author: "contributor", checks: [])
      @github = FakeGitHub.new(hits: hits, issue: issue, pr_author: pr_author, checks: checks)
      UpstreamGhPull.new(@ctx, github: @github)
    end

    def failing_check
      Check.new(id: 1, name: "rspec", status: "completed", conclusion: "failure",
                output: Output.new(title: "Tests failed", summary: "1 example, 1 failure",
                                   text: nil, annotations_count: 0))
    end

    def green_check
      Check.new(id: 2, name: "rspec", status: "completed", conclusion: "success", output: nil)
    end

    def upstream_dir
      @ctx.state_dir / "pr_reviews" / "opf-openproject" / "7"
    end

    def test_yields_reply_only_intent_for_an_allowlisted_mention
      gh = pull(issue: [issue_c(id: 1, body: "@chomper can you review this?", login: "thykel", at: "2026-06-20T09:00:00Z")])
      intents = gh.poll_intents("2026-06-01T00:00:00Z")
      assert_equal 1, intents.length
      i = intents.first
      assert i.reply_only, "upstream PR intents must be reply-only"
      assert_equal "opf/openproject", i.repo
      assert_equal "openproject", i.repo_name
      assert_equal 7, i.pr_number
      assert_equal "contributor/openproject", i.head_repo
      assert_equal "contrib-branch", i.branch
      assert_equal "sha9", i.head_sha, "the head SHA rides along so the review can match cached CI"
      assert_nil i.item_id
    end

    def test_failing_ci_is_cached_for_the_review
      gh = pull(issue: [issue_c(id: 1, body: "@chomper why is CI red?", login: "thykel", at: "2026-06-20T09:00:00Z")],
                checks: [failing_check])
      gh.poll_intents("2026-06-01T00:00:00Z")

      ci = JSON.parse((upstream_dir / "ci.json").read)
      assert_equal "sha9", ci["head_sha"]
      assert_equal ["rspec"], ci["failed"].map { |f| f["name"] }
      assert_equal [["opf/openproject", "sha9"]], @github.check_runs_calls,
                   "CI is read once for a handled PR"
    end

    def test_green_ci_writes_no_cache
      gh = pull(issue: [issue_c(id: 1, body: "@chomper thoughts?", login: "thykel", at: "2026-06-20T09:00:00Z")],
                checks: [green_check])
      gh.poll_intents("2026-06-01T00:00:00Z")

      refute (upstream_dir / "ci.json").exist?, "a green run leaves no ci.json; the review runs on the diff alone"
    end

    def test_ci_is_not_read_for_an_off_allowlist_mention
      gh = pull(issue: [issue_c(id: 9, body: "@chomper do it", login: "rando", at: "2026-06-20T09:00:00Z")],
                checks: [failing_check])
      capture_io { gh.poll_intents("2026-06-01T00:00:00Z") }

      assert_empty @github.check_runs_calls, "no CI spend on a PR whose only mention is off-allowlist"
    end

    def test_search_query_scopes_to_repo_cutoff_and_the_bot_login
      gh = pull(issue: [issue_c(id: 1, body: "@chomper-bot hi", login: "thykel", at: "2026-06-20T09:00:00Z")])
      gh.poll_intents("2026-06-01T00:00:00Z")
      q = @github.searches.first
      assert_includes q, "repo:opf/openproject"
      assert_includes q, "is:pr is:open"
      assert_includes q, "updated:>=2026-06-01"
      assert_includes q, "mentions:chomper-bot", "search uses the bot's GitHub login, resolved programmatically"
    end

    def test_search_excludes_the_bots_own_prs
      gh = pull
      gh.poll_intents("2026-06-01T00:00:00Z")
      assert_includes @github.searches.first, "-author:chomper-bot",
                      "chomper's own PRs are GhPull's territory — the upstream scanner must not re-handle them"
    end

    def test_the_bots_own_pr_is_skipped_even_when_the_search_returns_it
      gh = pull(pr_author: "chomper-bot",
                issue: [issue_c(id: 1, body: "@chomper refresh", login: "thykel", at: "2026-06-20T09:00:00Z")])
      assert_empty gh.poll_intents("2026-06-01T00:00:00Z")
      assert_empty @github.reacted, "an own PR must not be touched by the reply-only path at all"
    end

    def test_disabled_without_an_allowlist
      @ctx.allowed_gh_users = []
      gh = pull(issue: [issue_c(id: 1, body: "@chomper hi", login: "anyone", at: "2026-06-20T09:00:00Z")])
      assert_empty gh.poll_intents("2026-06-01T00:00:00Z")
      assert_equal 0, gh.scanned_count
      assert_empty @github.searches, "must not even search when no allowlist is set"
    end

    def test_off_allowlist_comment_is_skipped_and_cutoff_advances
      gh = pull(issue: [issue_c(id: 9, body: "@chomper do it", login: "rando", at: "2026-06-20T09:00:00Z")])
      capture_io { assert_empty gh.poll_intents("2026-06-01T00:00:00Z") }
      state = JSON.parse((upstream_dir / "gh_pr.json").read)
      assert_equal "2026-06-20T09:00:00Z", state["last_acted_comment_at"]
    end

    def test_state_lives_under_pr_reviews
      gh = pull
      gh.mark_acted("opf/openproject", 7, "2026-06-20T09:00:00Z")
      assert (upstream_dir / "gh_pr.json").exist?, "act-state lives at pr_reviews/<owner>-<repo>/<number>/"
    end
  end
end
