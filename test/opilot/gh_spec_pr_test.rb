require_relative "../test_helper"
require "tmpdir"

module OPilot
  # gh-agent's handling of a `pd` change proposal's PR. `pd propose` is
  # first-shot only, so this is the path a proposal is actually iterated on.
  class GhSpecPrTest < Minitest::Test
    User    = Struct.new(:login)
    RepoRef = Struct.new(:full_name)
    Head    = Struct.new(:ref, :sha, :repo)
    PR      = Struct.new(:state, :updated_at, :html_url, :title, :head, keyword_init: true)
    IssueC  = Struct.new(:id, :body, :user, :created_at, keyword_init: true)

    class FakeGitHub
      attr_reader :reacted, :check_runs_calls

      def initialize(pr:, issue: [])
        @pr = pr
        @issue = issue
        @reacted = []
        @check_runs_calls = 0
      end

      def pull_request(_repo, _num) = @pr
      def issue_comments(_repo, _num) = @issue
      def review_comments(_repo, _num) = []
      def reviews(_repo, _num) = []
      def react(repo, id, kind:, content: "eyes") = @reacted << [repo, id, kind]
      def login = "op-opilot"
      def check_runs(_repo, _ref)
        @check_runs_calls += 1
        []
      end
    end

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = Context.build(@tmpdir)
      @change = Helpers.change_dir(@ctx, "add-recurring-meetings")
      @change.mkpath
      (@change / "pr_url.txt").write("https://github.com/op-opilot/openproject/pull/14\n")
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def pr(state: "open", title: "[add-recurring-meetings] Change proposal")
      PR.new(state: state, updated_at: Time.parse("2026-08-03T10:00:00Z"),
             html_url: "https://github.com/op-opilot/openproject/pull/14", title: title,
             head: Head.new("spec/add-recurring-meetings", "sha1", RepoRef.new("op-opilot/openproject")))
    end

    def comment(body:, login: "thykel", at: "2026-08-03T11:00:00Z", id: 900)
      IssueC.new(id: id, body: body, user: User.new(login), created_at: Time.parse(at))
    end

    def pull(github)
      GhPull.new(@ctx, github: github)
    end

    def test_spec_pr_dirs_finds_changes_that_have_a_pr
      assert_equal ["add-recurring-meetings"], pull(FakeGitHub.new(pr: pr)).spec_pr_dirs.map { |d| d.basename.to_s }
    end

    def test_a_change_without_a_pr_is_not_polled
      (@change / "pr_url.txt").delete
      assert_empty pull(FakeGitHub.new(pr: pr)).spec_pr_dirs
    end

    def test_a_mention_yields_a_spec_intent
      gh = FakeGitHub.new(pr: pr, issue: [comment(body: "@opilot split the recurrence section")])
      intents = pull(gh).poll_intents("2026-08-01T00:00:00Z")

      assert_equal 1, intents.length
      intent = intents.first
      assert intent.spec?, "a proposal PR must be routed to the spec path"
      assert_equal "add-recurring-meetings", intent.spec_change_id
      assert_equal "add-recurring-meetings", intent.item_id
      assert_equal "spec/add-recurring-meetings", intent.branch
      assert_equal "op-opilot/openproject", intent.repo, "the PR lives in the bot's own fork"
      refute intent.reply_only, "opilot owns this branch and may push to it"
    end

    def test_the_repo_comes_from_the_tracker_not_the_prs_base
      # The PR's base repo is the bot's FORK, which matches no registry entry —
      # the change's tracker.json is what records which product repo it belongs to.
      store = PD::ChangeStore.new(@ctx, @ctx.default_repo)
      dir   = store.change_dir("add-recurring-meetings")
      dir.mkpath
      (dir / "tracker.json").write(JSON.generate("repo" => "openproject"))

      gh = FakeGitHub.new(pr: pr, issue: [comment(body: "@opilot tweak it")])
      assert_equal "openproject", pull(gh).poll_intents("2026-08-01T00:00:00Z").first.repo_name
    end

    def test_act_state_lands_in_the_change_namespace
      # A proposal is keyed by change id and has no work package yet, so its
      # act-state must not be written under work_packages/.
      p = pull(FakeGitHub.new(pr: pr))
      p.mark_acted("add-recurring-meetings", "openproject", "2026-08-03T11:00:00Z", spec: true)

      assert (@change / "gh_pr.json").exist?
      refute (Helpers.item_dir(@ctx, "add-recurring-meetings") / "repos").exist?
      assert_equal "2026-08-03T11:00:00Z",
                   JSON.parse((@change / "gh_pr.json").read)["last_acted_comment_at"]
    end

    def test_an_acted_comment_is_not_re_triggered
      gh = FakeGitHub.new(pr: pr, issue: [comment(body: "@opilot do it")])
      p  = pull(gh)
      assert_equal 1, p.poll_intents("2026-08-01T00:00:00Z").length

      p.mark_acted("add-recurring-meetings", "openproject", "2026-08-03T11:00:00Z", spec: true)
      assert_empty p.poll_intents("2026-08-01T00:00:00Z")
    end

    def test_a_spec_pr_never_produces_a_ci_intent
      # The diff is markdown; any CI on that branch is about code the change has
      # not touched, so chasing it would burn attempts on something unfixable here.
      gh = FakeGitHub.new(pr: pr, issue: [])
      assert_empty pull(gh).poll_intents("2026-08-01T00:00:00Z")
      assert_equal 0, gh.check_runs_calls, "a spec PR must not even read check runs"
    end

    def test_refresh_is_not_a_command_on_a_spec_pr
      # `@opilot refresh` means "merge base + fix CI + sweep feedback", none of
      # which applies to a proposal — it is just feedback text here.
      gh = FakeGitHub.new(pr: pr, issue: [comment(body: "@opilot refresh the tasks list")])
      assert_nil pull(gh).poll_intents("2026-08-01T00:00:00Z").first.command
    end

    def test_close_is_the_one_command_a_spec_pr_recognises
      # Unlike refresh, closing applies: the proposal PR is opilot's own, so
      # retiring it is the same need as retiring a code prototype.
      gh = FakeGitHub.new(pr: pr, issue: [comment(body: "@opilot close — we dropped this idea")])
      assert_equal :close, pull(gh).poll_intents("2026-08-01T00:00:00Z").first.command
    end

    def test_a_closed_proposal_pr_is_dropped_from_polling
      gh = FakeGitHub.new(pr: pr(state: "closed"))
      assert_empty pull(gh).poll_intents("2026-08-01T00:00:00Z")
      assert JSON.parse((@change / "gh_pr.json").read)["pr_done"]
    end

    # --- GhAgent routing --------------------------------------------------

    class RecordingRunner
      attr_reader :calls

      def initialize = @calls = []

      def revise_proposal(change_id, **kwargs)
        @calls << [change_id, kwargs]
        "REPLY: revised the tasks list"
      end
    end

    def test_gh_agent_routes_a_spec_intent_to_revise_proposal
      agent  = GhAgent.new(@ctx, pull: Object.new, upstream_pull: Object.new,
                           harness: Object.new, github: Object.new)
      runner = RecordingRunner.new
      agent.instance_variable_set(:@product_runner, runner)

      intent = GhIntent.new(item_id: "add-x", spec_change_id: "add-x", repo_name: "openproject",
                            repo: "op-opilot/openproject", head_repo: "op-opilot/openproject",
                            pr_number: 14, pr_url: "u", branch: "spec/add-x", kind: :issue,
                            comment_id: 900, text: "@opilot split it", user_login: "thykel",
                            comment_at: "2026-08-03T11:00:00Z")

      # Stub the git/GitHub side; the assertion is about routing and arguments.
      agent.define_singleton_method(:checkout_pr_branch) { |*| nil }
      agent.define_singleton_method(:post_reply) { |*| nil }
      agent.define_singleton_method(:spec_commit_pending?) { |*| false }
      agent.instance_variable_get(:@github).define_singleton_method(:fetch_branch) { |*, **| nil }
      agent.instance_variable_get(:@pull).define_singleton_method(:pr_dir) { |*, **| Pathname("/tmp") }

      capture_io { agent.handle(intent) }

      assert_equal 1, runner.calls.length
      change_id, kwargs = runner.calls.first
      assert_equal "add-x", change_id
      assert_equal "openproject", kwargs[:repo_name]
      assert_includes kwargs[:comment_section], "@opilot split it"
      assert_includes kwargs[:comment_section], "thykel"
    end

    def test_close_on_a_spec_pr_closes_it_instead_of_revising_the_proposal
      agent  = GhAgent.new(@ctx, pull: Object.new, upstream_pull: Object.new,
                           harness: Object.new, github: Object.new)
      runner = RecordingRunner.new
      agent.instance_variable_set(:@product_runner, runner)

      intent = GhIntent.new(item_id: "add-x", spec_change_id: "add-x", repo_name: "openproject",
                            repo: "op-opilot/openproject", head_repo: "op-opilot/openproject",
                            pr_number: 14, pr_url: "u", branch: "spec/add-x", kind: :issue,
                            command: :close, comment_id: 900, text: "@opilot close",
                            user_login: "thykel", comment_at: "2026-08-03T11:00:00Z")

      closed = []
      agent.define_singleton_method(:post_reply) { |*| nil }
      agent.instance_variable_get(:@github).define_singleton_method(:close_pr) { |r, n| closed << [r, n] }

      capture_io { agent.handle(intent) }

      assert_equal [["op-opilot/openproject", 14]], closed, "the proposal PR is closed unmerged"
      assert_empty runner.calls, "no revision call is spent answering \"close this\""
    end
  end
end
