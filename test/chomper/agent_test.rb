require_relative "../test_helper"

module Chomper
  class AgentTest < Minitest::Test
    # ── fakes ──────────────────────────────────────────────────────────────────

    class FakeClaude
      attr_reader :runs, :captures, :run_sessions, :capture_sessions
      def initialize(plan: "## Plan\nDo the thing.\n",
                     chat: "Here's my take.", impl: "", pr: "# PR title\nbody")
        @plan, @chat, @impl, @pr = plan, chat, impl, pr
        @runs = []; @captures = []; @run_sessions = []; @capture_sessions = []
      end

      def capture(prompt, tools: nil, model: nil, outfile:, session_file: nil)
        @captures << prompt
        @capture_sessions << session_file
        Pathname(outfile).write(@plan)
        @plan
      end

      def run(prompt, tools: nil, model: nil, session_file: nil)
        @runs << prompt
        @run_sessions << session_file
        return @chat if prompt.include?("You are chomper")
        return @pr   if prompt.include?("PR description")
        @impl
      end
    end

    # Mirrors the real Publish: open_pr writes the repo's pr_url.txt and returns
    # the URL.
    class FakePublish
      def initialize(state_dir, pr:); @state_dir = state_dir; @pr = pr; end
      def author_token; nil; end   # nil keeps adopt_github_author! a no-op
      def open_pr(id, _subject, _branch, repo)
        dir = @state_dir / "work_packages" / "op.example.com" / id.to_s / "repos" / repo.name
        dir.mkpath
        (dir / "pr_url.txt").write(@pr)
        @pr
      end
    end

    class FakePull
      attr_reader :acted, :developer_acted
      attr_accessor :related
      def initialize; @acted = []; @developer_acted = []; @related = []; end
      def mark_acted(id, at); @acted << [id, at]; end
      def mark_developer_acted(id); @developer_acted << id; end
      def record_chomper_comment(*, **); end
      def related_work_packages(_id); @related; end
    end

    # A publisher whose push always fails, to exercise the error path.
    class BoomPublish
      def author_token; nil; end
      def open_pr(*); raise "git push failed for branch fix/x"; end
    end

    class FakeCommit
      def sha; "abcdef1234567"; end
      def message; "fix: something"; end
    end

    class FakeLog
      def initialize(has) @has = has end
      def between(_a, _b); self; end
      def execute; @has ? [FakeCommit.new] : []; end
      def first; @has ? FakeCommit.new : nil; end
    end

    class FakeDiff
      def initialize(has_changes) @has_changes = has_changes end
      def entries; @has_changes ? [:change] : []; end
      def stats; { files: { "app/x.rb" => { insertions: 2, deletions: 1 } } }; end
    end

    # A clean tree, so Helpers#sync_base! is free to move HEAD to origin/<base>.
    class FakeStatus
      def changed; {}; end
      def added; {}; end
      def deleted; {}; end
    end

    # Minimal stand-in for the ruby-git worktree handle the Agent uses.
    class FakeWorktree
      attr_reader :checkouts, :commits, :configs, :fetched
      def initialize(has_commits: false, has_changes: true)
        @has_commits = has_commits
        @has_changes = has_changes
        @checkouts = []; @commits = []; @configs = []; @fetched = []
      end
      def revparse(_ref); "sha"; end                 # branch "exists" → checkout, no create
      def checkout(branch, **_opts); @checkouts << branch; end
      def fetch(remote, **opts); @fetched << [remote, opts]; end
      def status; FakeStatus.new; end
      def config(key, value); @configs << [key, value]; end
      def log(*_args); FakeLog.new(@has_commits); end
      def add(**_opts); end
      def diff(*_args); FakeDiff.new(@has_changes); end
      def commit(msg); @commits << msg; @has_commits = true; end
    end

    # ── harness ────────────────────────────────────────────────────────────────

    def setup
      @tmpdir = Dir.mktmpdir
      state_dir = Pathname(@tmpdir) / ".chomper"
      state_dir.mkpath
      registry = Registry.build(script_dir: Pathname(@tmpdir), state_dir: state_dir, op_repo_path: @tmpdir)
      @ctx = Struct.new(
        :script_dir, :state_dir, :op_url, :token, :state_container,
        :allowed_op_user_ids, :log_file, :progress_file, :repos
      ) do
        def default_repo; repos.default; end
        def op_host; "op.example.com"; end                 # WP mirror namespace (derived from op_url)
      end.new(
        Pathname(@tmpdir), state_dir, "https://op.example.com", "tok",
        "/state", [],
        Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt", registry
      )

      @repo    = registry.default
      @claude  = FakeClaude.new
      @publish = FakePublish.new(@ctx.state_dir, pr: "https://github.com/o/r/pull/7")
      @pull    = FakePull.new
      @agent   = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      @worktree = FakeWorktree.new
      inject_worktree(@agent, @worktree)

      # @chomper notes are posted to the activities endpoint.
      @notes = []
      @note_visibility = []
      stub_request(:post, %r{/work_packages/\d+/activities}).to_return do |req|
        body = JSON.parse(req.body)
        @notes << body.dig("comment", "raw")
        @note_visibility << body["internal"]
        { status: 201, body: "{}" }
      end
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def intent(command, item_id: "42", subject: "Fix the bug", type: "bug", text: nil, user: nil,
               user_href: nil, internal: nil, comment_at: "2024-02-01T00:00:00Z", source: nil)
      Intent.new(item_id: item_id, subject: subject, type: type, command: command, text: text,
                 comment_at: comment_at, user: user, user_href: user_href, internal: internal,
                 source: source)
    end

    # Make worktree(repo) return the same fake for every repo, so tests can drive
    # and inspect one handle regardless of which repo a fix targets.
    def inject_worktree(agent, wt)
      agent.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })
    end

    def plan_path(id = "42"); @ctx.state_dir / "work_packages" / "op.example.com" / id / "plan.md"; end
    def pr_url_path(id = "42")
      dir = @ctx.state_dir / "work_packages" / "op.example.com" / id / "repos" / "openproject"
      dir.mkpath
      dir / "pr_url.txt"
    end

    # ── produce_plan ────────────────────────────────────────────────────────

    def test_produce_plan_saves_plan_and_returns_ok
      st = @agent.send(:state_for, "42", "Fix the bug")
      assert_equal :ok, @agent.send(:produce_plan, st, nil)
      assert plan_path.exist?
    end

    def test_produce_plan_needs_info_posts_questions_and_writes_no_plan
      @claude = FakeClaude.new(plan: "NEEDS_INFO\n### Questions for the reporter\n- How do I reproduce it?")
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      inject_worktree(@agent, FakeWorktree.new)

      st = @agent.send(:state_for, "42", "Fix the bug")
      assert_equal :needs_info, @agent.send(:produce_plan, st, nil)
      refute plan_path.exist?
      assert(@notes.any? { |n| n.include?("How do I reproduce it?") })
    end

    # ── implementation options ────────────────────────────────────────────────

    # What a `ship` plan call answers with when the fix has more than one shape
    # (Prompts::OPTIONS_CONTRACT).
    OPTIONS_ANSWER = <<~TEXT
      OPTIONS
      1 | Guard the paste | I stop the broken paste and insert plain text. | openproject | small
      2 | Rebuild the editor | I rebuild the bundled editor and show one message. | openproject | large
    TEXT

    def options_path(id = "42")
      @ctx.state_dir / "work_packages" / "op.example.com" / id / "options.json"
    end

    # An agent whose writer answers every plan call with `plan`.
    def agent_answering(plan)
      @claude = FakeClaude.new(plan: plan)
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      inject_worktree(@agent, @worktree)
      @agent
    end

    def save_options(count = 2)
      options_path.parent.mkpath
      rows = (1..count).map do |n|
        { "n" => n, "title" => "Option #{n}", "summary" => "I do thing #{n}.",
          "repos" => ["openproject"], "size" => "small" }
      end
      options_path.write(JSON.generate(rows))
    end

    def test_ship_offers_options_and_writes_neither_plan_nor_code
      agent_answering(OPTIONS_ANSWER).handle(intent(:ship))

      assert options_path.exist?, "the offered options must be saved — a number means nothing without them"
      refute plan_path.exist?
      assert_empty @claude.runs, "must not implement while it waits for a choice"
      refute pr_url_path.exist?
      assert_includes @notes.last, "**1 — Guard the paste**"
      assert_includes @notes.last, "@chomper ship 1"
    end

    def test_ship_with_an_option_number_plans_that_option_and_ships
      save_options
      @agent.handle(intent(:ship, text: "2"))

      assert(@claude.captures.any? { |p| p.include?("chose option 2") },
             "the chosen option must reach the plan call as its focus")
      assert plan_path.exist?
      assert pr_url_path.exist?
    end

    def test_ship_repeats_a_standing_offer_without_calling_claude
      save_options
      @agent.handle(intent(:ship))

      assert_empty @claude.captures, "the saved options are re-posted, not regenerated"
      assert_includes @notes.last, "Pick one"
    end

    def test_ship_with_free_text_beside_a_standing_offer_plans_instead_of_re_offering
      save_options
      @agent.handle(intent(:ship, text: "do it with a toast instead"))

      assert plan_path.exist?, "free text is direction, not a selection"
      assert pr_url_path.exist?
    end

    # A Developers handover names no commenter, so an internal offer would reach
    # nobody who can answer it.
    def test_developer_handover_offers_options_publicly
      agent_answering(OPTIONS_ANSWER).handle(intent(:ship, source: :developer))
      assert_equal false, @note_visibility.last
    end

    def test_offer_from_an_internal_comment_stays_internal
      agent_answering(OPTIONS_ANSWER).handle(intent(:ship, internal: true))
      assert_equal true, @note_visibility.last
    end

    def test_offer_names_the_allowlist_when_one_is_set
      @ctx.allowed_op_user_ids = ["7"]
      agent_answering(OPTIONS_ANSWER).handle(intent(:ship))
      assert_includes @notes.last, "allowlist"
    end

    # `@chomper plan` is already a request to review one approach.
    def test_plan_trigger_never_asks_for_options
      agent_answering(OPTIONS_ANSWER).handle(intent(:plan))

      refute options_path.exist?
      refute(@claude.captures.any? { |p| p.include?("Offer options ONLY when") },
             "the options gate belongs to ship, not plan")
    end

    def test_options_without_a_usable_list_asks_once_for_a_plan_then_gives_up
      agent = agent_answering("OPTIONS\nnot a list at all\n")
      st    = agent.send(:state_for, "42", "Fix the bug")

      assert_equal :failed, agent.send(:produce_plan, st, nil, allow_options: true)
      assert_equal 2, @claude.captures.length, "one retry, never a loop"
      refute plan_path.exist?
      refute options_path.exist?
    end

    def test_parse_options_skips_junk_and_orders_by_number
      rows = @agent.send(:parse_options,
                         "OPTIONS\nnonsense\n2 | B | second | openproject | large\n" \
                         "**1** | A | first | openproject | small\n")

      assert_equal [1, 2], rows.map { |o| o["n"] }
      assert_equal "first", rows.first["summary"]
    end

    # ── ship ──────────────────────────────────────────────────────────────────

    def test_ship_reports_existing_pr_without_reimplementing
      st = @agent.send(:state_for, "42", "Fix the bug")
      pr_url_path.write("https://github.com/o/r/pull/1\n")

      @agent.send(:ship, st)
      assert_empty @claude.runs, "should not implement when already shipped"
      assert(@notes.any? { |n| n.include?("already shipped") })
    end

    def test_ship_implements_commits_and_opens_pr
      st = @agent.send(:state_for, "42", "Fix the bug")
      plan_path.write("## Plan\nDo it.\n")

      @agent.send(:ship, st)
      assert(@notes.any? { |n| n.include?("https://github.com/o/r/pull/7") })
      assert pr_url_path.exist?
    end

    def test_ship_skips_implementation_when_branch_already_has_commits
      st = @agent.send(:state_for, "42", "Fix the bug")
      plan_path.write("## Plan\nDo it.\n")
      inject_worktree(@agent, FakeWorktree.new(has_commits: true))

      @agent.send(:ship, st)
      refute(@claude.runs.any? { |p| p.include?("APPROVED PLAN") }, "should not re-run implement")
      assert pr_url_path.exist?
    end

    def test_checkout_branch_tracks_the_pr_branch_not_dev
      st = @agent.send(:state_for, "42", "Fix the bug", "bug")
      @agent.send(:checkout_branch, st, @repo)

      configs = @worktree.configs
      assert_includes configs, ["branch.#{st.branch}.remote", "origin"]
      assert_includes configs, ["branch.#{st.branch}.merge", "refs/heads/#{st.branch}"],
                      "the fix branch must track its own PR branch, never origin/dev"
    end

    # ── multi-repo selection ──────────────────────────────────────────────────

    def test_plan_with_a_repos_line_ships_a_pr_to_each_chosen_repo
      (Pathname(@tmpdir) / "repos.json").write(JSON.generate(
        "repos" => [
          { "name" => "openproject", "upstream" => "opf/openproject", "base" => "dev", "shared_repo_path" => @tmpdir },
          { "name" => "ck", "upstream" => "opf/commonmark-ckeditor-build", "base" => "main" }
        ]
      ))
      @ctx.repos = Registry.build(script_dir: Pathname(@tmpdir), state_dir: @ctx.state_dir, op_repo_path: @tmpdir)
      @claude = FakeClaude.new(plan: "REPOS: openproject, ck\n## Plan\nDo it across both.\n")
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      inject_worktree(@agent, FakeWorktree.new)

      @agent.handle(intent(:ship))

      items = @ctx.state_dir / "work_packages" / "op.example.com" / "42"
      assert (items / "repos" / "openproject" / "pr_url.txt").exist?, "openproject PR opened"
      assert (items / "repos" / "ck" / "pr_url.txt").exist?, "ck PR opened"
      assert_equal %w[ck openproject], JSON.parse((items / "target_repos.json").read).sort
      refute_includes plan_path.read, "REPOS:", "the REPOS line is stripped from the saved plan"
    end

    def test_plan_without_a_repos_line_falls_back_to_the_default_repo
      @agent.handle(intent(:ship))   # FakeClaude's plan has no REPOS line
      assert pr_url_path.exist?, "ships to the default repo when no REPOS line is given"
    end

    # ── handlers / routing ────────────────────────────────────────────────────

    def test_handle_approve_without_plan_guards
      @agent.handle(intent(:approve))
      refute pr_url_path.exist?
      assert(@notes.any? { |n| n.include?("no plan yet") })
    end

    def test_reply_is_internal_when_trigger_is_internal
      @agent.handle(intent(:approve, internal: true))
      assert_equal [true], @note_visibility
    end

    def test_reply_is_public_when_trigger_is_public
      @agent.handle(intent(:approve, internal: false))
      assert_equal [false], @note_visibility
    end

    def test_reply_defaults_to_internal_when_visibility_unknown
      @agent.handle(intent(:approve, internal: nil))
      assert_equal [true], @note_visibility
    end

    def test_handle_ship_skips_ship_when_needs_info
      @claude = FakeClaude.new(plan: "NEEDS_INFO\n### Questions for the reporter\n- repro?")
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      inject_worktree(@agent, FakeWorktree.new)

      @agent.handle(intent(:ship))
      refute pr_url_path.exist?, "must not ship when info is missing"
    end

    # The clone is otherwise wherever the last run left it: `./chomper` fetches
    # each base once at launch and never moves the working tree onto it, and no
    # run checks the tree back off its fix branch. So a long-lived agent loop
    # planned against months-old code, or against an unrelated WP's fix branch.
    def test_planning_syncs_the_clone_to_current_upstream_first
      wt = FakeWorktree.new
      inject_worktree(@agent, wt)

      @agent.handle(intent(:plan))

      assert_includes wt.fetched, ["origin", { ref: "dev" }],
                      "the base must be re-fetched at plan time, not trusted from launch"
      assert_includes wt.checkouts, "origin/dev",
                      "and the tree moved onto it before Claude reads anything"
    end

    def test_chat_syncs_the_clone_before_answering
      wt = FakeWorktree.new
      inject_worktree(@agent, wt)

      @agent.handle(intent(:chat))

      assert_includes wt.fetched, ["origin", { ref: "dev" }]
      assert_includes wt.checkouts, "origin/dev"
    end

    def test_handle_ship_plans_and_ships
      @agent.handle(intent(:ship))
      assert plan_path.exist?
      assert pr_url_path.exist?
      assert(@notes.any? { |n| n.include?("https://github.com/o/r/pull/7") })
    end

    def test_handle_ship_threads_one_session_through_plan_implement_and_pr
      @agent.handle(intent(:ship))
      session = @ctx.state_dir / "work_packages" / "op.example.com" / "42" / "session_id"
      assert_equal [session], @claude.capture_sessions.uniq, "plan must use the per-WP session"
      assert_equal [session], @claude.run_sessions.uniq, "implement and PR description must resume the planning session"
    end

    def test_handle_plan_posts_the_plan_text_as_a_comment
      @agent.handle(intent(:plan))
      note = @notes.find { |n| n.include?("Do the thing.") }
      assert note, "the plan content should be posted to the WP"
      assert_includes note, "@chomper approve"
    end

    def test_handle_plan_waits_for_approval_without_shipping
      @agent.handle(intent(:plan))
      refute pr_url_path.exist?, "a plan must wait for @chomper approve before shipping"
    end

    def test_handle_chat_posts_reply_and_changes_no_files
      @agent.handle(intent(:chat, text: "what about tests?"))
      refute plan_path.exist?
      refute pr_url_path.exist?
      assert_includes @notes, "Here's my take."
    end

    # ── related work packages ─────────────────────────────────────────────────

    def related_path(id = "42"); @ctx.state_dir / "work_packages" / "op.example.com" / id / "related.json"; end

    def test_handle_plan_writes_related_index_and_injects_it
      @pull.related = [{ "id" => "200", "relation" => "relates", "subject" => "Other", "status" => "New" }]
      @agent.handle(intent(:plan))

      assert related_path.exist?, "the related index should be written"
      index = JSON.parse(related_path.read)
      assert_equal "/state/work_packages/op.example.com/200/item.json", index.first["item_path"]

      plan_prompt = @claude.captures.find { |p| p.include?("AVAILABLE REPOS") }
      assert_includes plan_prompt, "RELATED:"
      assert_includes plan_prompt, "/state/work_packages/op.example.com/42/related.json"
    end

    def test_handle_chat_injects_related_context
      @pull.related = [{ "id" => "50", "relation" => "parent", "subject" => "Epic", "status" => "New" }]
      @agent.handle(intent(:chat, text: "how does this relate to the epic?"))

      chat_prompt = @claude.runs.find { |p| p.include?("You are chomper") }
      assert_includes chat_prompt, "RELATED:"
    end

    def test_no_related_means_no_index_and_no_related_line
      @agent.handle(intent(:plan))   # FakePull.related defaults to []
      refute related_path.exist?
      plan_prompt = @claude.captures.find { |p| p.include?("AVAILABLE REPOS") }
      refute_includes plan_prompt, "RELATED:"
    end

    def test_handle_and_ack_marks_but_posts_no_note_on_error
      agent = Agent.new(@ctx, pull: @pull, claude: @claude, publish: BoomPublish.new)
      inject_worktree(agent, FakeWorktree.new)
      plan_path.dirname.mkpath
      plan_path.write("## Plan\nDo it.\n")   # approve will reach the failing push

      agent.send(:handle_and_ack, intent(:approve, user: "Jane", user_href: "/api/v3/users/2"))

      # Acked despite the failure → no infinite re-try on the next poll.
      assert_equal [["42", "2024-02-01T00:00:00Z"]], @pull.acted
      # A handled error is logged, not posted — no error note left on the WP.
      refute(@notes.any? { |n| n.include?("hit an error") }, "must not post an error note on the WP")
      refute pr_url_path.exist?
    end

    # ── Developer trigger ────────────────────────────────────────────────────

    def developer_intent
      intent(:ship, source: :developer, comment_at: nil, text: "")
    end

    def test_developer_intent_plans_ships_and_acks_the_marker
      @agent.send(:handle_and_ack, developer_intent)

      assert plan_path.exist?
      assert pr_url_path.exist?
      assert_equal ["42"], @pull.developer_acted
      assert_empty @pull.acted, "must not touch last_acted_comment_at — that would reopen old comment triggers"
      refute(@notes.any? { |n| n.include?("<mention") }, "no commenter to address")
      assert(@note_visibility.all?, "Developer-trigger replies default to internal")
    end

    def test_developer_intent_acks_the_marker_on_error
      agent = Agent.new(@ctx, pull: @pull, claude: @claude, publish: BoomPublish.new)
      inject_worktree(agent, FakeWorktree.new)

      agent.send(:handle_and_ack, developer_intent)

      assert_equal ["42"], @pull.developer_acted
      assert_empty @pull.acted
    end

    def test_replies_mention_the_requesting_user
      @agent.handle(intent(:approve, user: "Jane Doe", user_href: "/api/v3/users/2"))
      note = @notes.last
      assert_includes note, %q(<mention class="mention" data-id="2" data-type="user" data-text="Jane Doe">@Jane Doe</mention>)
      assert_includes note, "no plan yet"
    end
  end
end
