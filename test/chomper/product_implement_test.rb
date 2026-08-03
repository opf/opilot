require_relative "../test_helper"
require "tmpdir"

module Chomper
  # `pd implement` — the stage that builds ONE generated work package from the
  # spec the reviewer approved. What matters here is the scoping: the right
  # section reaches the prompt, the spec tree stays the harness's, and the
  # checkboxes are ticked only once there is a commit to tick them for.
  class ProductImplementTest < Minitest::Test
    # Git and GitHub are the parts a unit test can't drive; everything above them
    # is the real runner.
    class TestRunner < ProductRunner
      attr_reader :checked_out, :commits, :pr_descriptions

      def initialize(*args, produces_commit: true, **kwargs)
        super(*args, **kwargs)
        @produces_commit = produces_commit
        @checked_out     = []
        @commits         = []
        @pr_descriptions = []
        @has_commits     = false
      end

      private

      def checkout_branch(st, repo)
        @checked_out << [st.branch, repo.name]
      end

      def branch_has_commits?(_st, _repo)
        @has_commits
      end

      def commit(st, repo)
        return false unless @produces_commit
        @commits << [st.branch, repo.name]
        @has_commits = true
      end

      def generate_pr_description(st, repo, model: nil)
        @pr_descriptions << st.subject
        st.pr_desc_file(repo).write("# #{st.subject}\n")
      end
    end

    class FakePull
      def initialize(items = {})
        @items = items
      end

      def fetch_single_item(wp_id)
        item = @items[wp_id.to_s]
        return nil unless item
        dir = Helpers.item_dir(Context.build(item[:root]), wp_id)
        dir.mkpath
        (dir / "item.json").write(JSON.generate(item[:data]))
        item[:data]
      end
    end

    class FakePublish
      attr_reader :opened

      def initialize(url: "https://github.com/opf/openproject/pull/77")
        @url    = url
        @opened = []
      end

      def author_token = "tok"
      def login = "op-chomper"

      def open_pr(item_id, subject, branch, repo)
        @opened << { id: item_id, subject: subject, branch: branch, repo: repo.name }
        @url
      end
    end

    class FakeOP
      attr_reader :comments

      def initialize
        @comments = []
      end

      def post_activity(wp_id, comment:, internal: true)
        @comments << [wp_id, comment]
        [201, {}]
      end
    end

    # Writes whatever the block says on each call and records the prompts.
    class FakeClaude
      attr_reader :prompts

      def initialize(&on_run)
        @prompts = []
        @on_run  = on_run
      end

      def run(prompt, tools: nil, model: nil, session_file: nil)
        @prompts << prompt
        @on_run ? @on_run.call : ""
      end
    end

    TASKS = <<~MD
      ## RRule parsing (#501)
      - [ ] parse the rule
      - [ ] reject junk

      ## Materialisation (#502)
      - [ ] expand occurrences
    MD

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = Context.build(@tmpdir)
      @repo   = @ctx.default_repo
      @repo.worktree_host.mkpath
      Git.init(@repo.worktree_host.to_s)

      @store = ChangeStore.new(@ctx, @repo)
      (@store.tree / "changes").mkpath
      (@store.tree / "config.yaml").write("schema: spec-driven\n")
      dir = @store.change_dir("add-x")
      dir.mkpath
      (dir / "proposal.md").write("# Recurring meetings\nWhy this exists.\n")
      (dir / "tasks.md").write(TASKS)
      (dir / "intake").mkpath

      @op      = FakeOP.new
      @publish = FakePublish.new
      @item    = { "id" => "501", "subject" => "RRule parsing", "type" => "IMPLEMENTATION",
                   "url" => "#{@ctx.op_url}/work_packages/501", "description" => "" }
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def runner(claude: nil, items: nil, produces_commit: true)
      items ||= { "501" => { root: @tmpdir, data: @item } }
      TestRunner.new(@ctx, op: @op, intake: Object.new, publish: @publish,
                     claude: claude || FakeClaude.new, pull: FakePull.new(items),
                     produces_commit: produces_commit)
    end

    def implement(run, *args)
      out = nil
      result = nil
      out, = capture_io { result = run.run(["implement", *args]) }
      [result, out]
    end

    def store_tasks
      (@store.change_dir("add-x") / "tasks.md").read
    end

    def item_state_dir
      Helpers.item_dir(@ctx, "501")
    end

    # --- the happy path ---------------------------------------------------

    def test_it_implements_the_section_commits_and_ships_a_draft_pr
      run = runner
      _, out = implement(run, "501")

      assert_equal [["implementation/501-rrule-parsing", "openproject"]], run.checked_out
      assert_equal 1, run.commits.length
      assert_equal 1, @publish.opened.length
      assert_equal "RRule parsing", @publish.opened.first[:subject]
      assert_equal "implementation/501-rrule-parsing", @publish.opened.first[:branch]
      assert_match(/Draft PR/, out)
      assert_equal [["501", %r{pull/77}]].length, @op.comments.length
      assert_match(%r{Implementation PR for `add-x`.*pull/77}, @op.comments.first.last)
    end

    def test_the_prompt_carries_this_section_only
      claude = FakeClaude.new
      implement(runner(claude: claude), "501")

      prompt = claude.prompts.first
      assert_includes prompt, "## RRule parsing"
      assert_includes prompt, "- [ ] parse the rule"
      refute_includes prompt, "expand occurrences",
                      "a sibling section is another work package's PR"
      assert_includes prompt, "/repos/openproject/openspec/changes/add-x/proposal.md"
      assert_includes prompt, "/state/work_packages/#{@ctx.op_host}/501/item.json"
      assert_includes prompt, "Do NOT edit anything under"
    end

    def test_it_writes_the_plan_file_the_pr_and_gh_agent_expect
      implement(runner, "501")

      plan = (item_state_dir / "plan.md").read
      assert_includes plan, "# RRule parsing"
      assert_includes plan, "- [ ] parse the rule"
      assert_includes plan, "Recurring meetings", "the proposal is the plan for a pd work package"
      assert_equal ["openproject"], JSON.parse((item_state_dir / "target_repos.json").read),
                   "the clone has to be discoverable by `pr` and gh-agent"
    end

    def test_the_section_is_ticked_and_its_siblings_are_not
      implement(runner, "501")

      assert_includes store_tasks, "## RRule parsing (#501)\n- [x] parse the rule\n- [x] reject junk"
      assert_includes store_tasks, "## Materialisation (#502)\n- [ ] expand occurrences",
                      "another work package's checkboxes are not this run's to tick"
    end

    # --- scope ------------------------------------------------------------

    def test_a_stray_spec_edit_is_discarded_and_the_implementation_survives
      # The mirror image of propose's write scope: there a planning run had
      # touched source and the run was discarded; here the spec is only the input,
      # so failing would throw away a working implementation over a stray edit.
      claude = FakeClaude.new do
        (@repo.worktree_host / "app.rb").write("real work\n")
        (@store.working_change_dir("add-x") / "proposal.md").write("rewritten by the implementer\n")
        "done"
      end
      _, out = implement(runner(claude: claude), "501")

      assert_equal "# Recurring meetings\nWhy this exists.\n",
                   (@store.change_dir("add-x") / "proposal.md").read,
                   "the store stays the source of truth for the spec"
      assert_equal "real work\n", (@repo.worktree_host / "app.rb").read, "the code survives"
      assert_equal 1, @publish.opened.length, "and the work package still ships"
      assert_match(/restoring them from the store/, out)
    end

    def test_nothing_is_ticked_or_shipped_when_no_code_was_produced
      _, out = implement(runner(produces_commit: false), "501")

      assert_match(/No changes produced/, out)
      assert_empty @publish.opened
      assert_includes store_tasks, "- [ ] parse the rule",
                      "an unticked section is the honest record of work not done"
    end

    def test_an_already_shipped_work_package_is_reported_and_skipped
      claude = FakeClaude.new { raise "must not run" }
      run    = runner(claude: claude)
      st_dir = item_state_dir / "repos" / "openproject"
      st_dir.mkpath
      (st_dir / "pr_url.txt").write("https://github.com/opf/openproject/pull/12\n")

      _, out = implement(run, "501")
      assert_match(%r{Already shipped: https://github.com/opf/openproject/pull/12}, out)
      assert_empty run.commits
      assert_empty @publish.opened
    end

    # --- resolution -------------------------------------------------------

    def test_the_change_is_resolved_from_the_work_package_id
      # No change id is passed, and the store lives under one of five registry
      # repos — the binding in tasks.md is what makes that resolvable.
      run = runner(items: { "502" => { root: @tmpdir, data: @item.merge("id" => "502", "subject" => "Materialisation") } })
      implement(run, "502")

      assert_equal [["implementation/502-materialisation", "openproject"]], run.checked_out
      assert_includes store_tasks, "## Materialisation (#502)\n- [x] expand occurrences"
    end

    def test_an_unbound_id_says_what_is_bound
      error = assert_raises(Chomper::FatalError) { implement(runner, "999") }
      assert_match(/not bound to any tasks\.md section/, error.message)
      assert_match(/pd generate-wp/, error.message)
      assert_match(/#501\s+add-x — RRule parsing/, error.message)
    end

    def test_one_bad_id_does_not_cost_the_others_their_run
      items = { "501" => { root: @tmpdir, data: @item } }
      run   = runner(items: items)
      _, out = implement(run, "999", "501")

      assert_equal 1, @publish.opened.length, "the valid work package still ships"
      assert_match(/not bound to any tasks\.md section/, out)
    end

    def test_a_missing_openproject_mirror_does_not_stop_the_run
      # The spec is the requirement and it is already on disk; losing the work
      # package's own comments is a degradation, not a failure.
      run = runner(items: {})
      _, out = implement(run, "501")

      assert_equal 1, @publish.opened.length
      assert_match(/working from the spec alone/, out)
      assert_equal "RRule parsing", @publish.opened.first[:subject],
                   "the section title stands in for the missing subject"
    end

    def test_it_needs_at_least_one_id
      error = assert_raises(Chomper::FatalError) { implement(runner) }
      assert_match(/work-package id is required/, error.message)
    end
  end
end
