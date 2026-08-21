require_relative "../test_helper"

module OPilot
  class AgentTest < Minitest::Test
    # ── fakes ──────────────────────────────────────────────────────────────────

    # The git doubles are shared (test/support/fixtures.rb); aliased here so the
    # nested FakeWorktree below resolves them lexically.
    FakeCommit = TestFixtures::FakeCommit
    FakeLog    = TestFixtures::FakeLog
    FakeDiff   = TestFixtures::FakeDiff

    class FakeHarness
      attr_reader :runs, :captures, :run_sessions, :capture_sessions
      def initialize(plan: "## Plan\nDo the thing.\n",
                     chat: "Here's my take.", impl: "", pr: "# PR title\nbody",
                     draft: "SUBJECT: Split the login toast out\nTYPE: Feature\n\nRosanna asks for a toast.\n")
        @plan, @chat, @impl, @pr, @draft = plan, chat, impl, pr, draft
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
        # Checked before the chat prompt: the create-wp draft prompt also opens
        # with "You are opilot".
        return draft_answer if prompt.include?("create a NEW work package")
        return @chat if prompt.include?("You are opilot")
        return @pr   if prompt.include?("PR description")
        @impl
      end

      # The draft answer, so a subclass can vary it per call (a retry).
      def draft_answer; @draft; end
    end

    # A harness that answers each successive #capture with the next entry in
    # `plans`, holding on the last entry once exhausted. Used to drive a
    # writer's retry (e.g. an unusable OPTIONS answer followed by a good one).
    class SequencedHarness < FakeHarness
      def initialize(plans)
        super()
        @plans = plans
      end

      def capture(prompt, tools: nil, model: nil, outfile:, session_file: nil)
        @captures << prompt
        @capture_sessions << session_file
        plan = @plans[@captures.length - 1] || @plans.last
        Pathname(outfile).write(plan)
        plan
      end
    end

    # A harness whose create-wp draft differs per call, to drive the one bounded
    # retry after an unusable answer.
    class SequencedDraftHarness < FakeHarness
      def initialize(drafts)
        super()
        @drafts = drafts
        @draft_calls = 0
      end

      def draft_answer
        @draft_calls += 1
        @drafts[@draft_calls - 1] || @drafts.last
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
      attr_reader :acted
      attr_accessor :related
      def initialize; @acted = []; @related = []; end
      def mark_acted(id, at); @acted << [id, at]; end
      def record_opilot_comment(*, **); end
      def related_work_packages(_id); @related; end
    end

    # A publisher whose push always fails, to exercise the error path.
    class BoomPublish
      def author_token; nil; end
      def open_pr(*); raise "git push failed for branch fix/x"; end
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
      def config_set(key, value); @configs << [key, value]; end
      def log(*_args); FakeLog.new(@has_commits ? [FakeCommit.new] : []); end
      def add(**_opts); end
      def diff(*_args); FakeDiff.new(@has_changes); end
      def commit(msg); @commits << msg; @has_commits = true; end
    end

    # ── harness ────────────────────────────────────────────────────────────────

    include TestFixtures

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = build_ctx(@tmpdir)
      registry = @ctx.repos

      @repo    = registry.default
      @harness  = FakeHarness.new
      @publish = FakePublish.new(@ctx.state_dir, pr: "https://github.com/o/r/pull/7")
      @pull    = FakePull.new
      @agent   = Agent.new(@ctx, pull: @pull, harness: @harness, publish: @publish)
      @worktree = FakeWorktree.new
      inject_worktree(@agent, @worktree)

      # @opilot notes are posted to the activities endpoint.
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
               user_href: nil, internal: nil, comment_at: "2024-02-01T00:00:00Z")
      Intent.new(item_id: item_id, subject: subject, type: type, command: command, text: text,
                 comment_at: comment_at, user: user, user_href: user_href, internal: internal)
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
      @harness = FakeHarness.new(plan: "NEEDS_INFO\n### Questions for the reporter\n- How do I reproduce it?")
      @agent  = Agent.new(@ctx, pull: @pull, harness: @harness, publish: @publish)
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

    # The common case: one named approach, with its plan in the same response
    # (Prompts::OPTIONS_CONTRACT — no real choice, so no reason to stop).
    SINGLE_OPTION_ANSWER = <<~TEXT
      OPTIONS
      1 | Guard the paste | I stop the broken paste and insert plain text. | openproject | small

      ## Plan: #42 — Fix the bug
      REPOS: openproject
      ### Files to change
      ### Approach
      ### Tests to run
      ### Risks / assumptions
    TEXT

    def options_path(id = "42")
      @ctx.state_dir / "work_packages" / "op.example.com" / id / "options.json"
    end

    # An agent whose writer answers every plan call with `plan`.
    def agent_answering(plan)
      @harness = FakeHarness.new(plan: plan)
      @agent  = Agent.new(@ctx, pull: @pull, harness: @harness, publish: @publish)
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
      assert_empty @harness.runs, "must not implement while it waits for a choice"
      refute pr_url_path.exist?
      assert_includes @notes.last, "**1 — Guard the paste**"
      assert_includes @notes.last, "@opilot build 1"
    end

    # No real choice to offer: the writer names the one approach and keeps
    # going into its plan in the same response, so opilot announces it and
    # ships immediately — no options.json, no waiting on a reply.
    def test_ship_with_one_named_approach_announces_and_ships_without_waiting
      agent_answering(SINGLE_OPTION_ANSWER).handle(intent(:ship))

      refute options_path.exist?, "one approach is not a choice to save or offer"
      assert plan_path.exist?
      refute_includes plan_path.read, "OPTIONS", "the header must not leak into the saved plan"
      assert pr_url_path.exist?, "it ships in the same call, not after a reply"
      assert(@notes.any? { |n| n.include?("This is a straightforward problem") && n.include?("Guard the paste") },
             "the chosen approach is announced before implementing")
    end

    def test_ship_with_an_option_number_plans_that_option_and_ships
      save_options
      @agent.handle(intent(:ship, text: "2"))

      assert(@harness.captures.any? { |p| p.include?("chose option 2") },
             "the chosen option must reach the plan call as its focus")
      assert plan_path.exist?
      assert pr_url_path.exist?
    end

    def test_ship_repeats_a_standing_offer_without_calling_harness
      save_options
      @agent.handle(intent(:ship))

      assert_empty @harness.captures, "the saved options are re-posted, not regenerated"
      assert_includes @notes.last, "Pick one"
    end

    def test_ship_with_free_text_beside_a_standing_offer_plans_instead_of_re_offering
      save_options
      @agent.handle(intent(:ship, text: "do it with a toast instead"))

      assert plan_path.exist?, "free text is direction, not a selection"
      assert pr_url_path.exist?
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

    # A settled approach must never re-open the question.
    def test_ship_with_a_saved_plan_never_asks_for_options
      plan_path.dirname.mkpath
      plan_path.write("## Plan\nDo it.\n")
      agent_answering(OPTIONS_ANSWER).handle(intent(:ship))

      refute options_path.exist?
      refute(@harness.captures.any? { |p| p.include?("Before the plan, always name the approach") },
             "the options gate is only for a work package with no approach yet")
    end

    def test_options_without_a_usable_list_asks_once_for_a_plan_then_gives_up
      agent = agent_answering("OPTIONS\nnot a list at all\n")
      st    = agent.send(:state_for, "42", "Fix the bug")

      assert_equal :failed, agent.send(:produce_plan, st, nil, allow_options: true)
      assert_equal 2, @harness.captures.length, "one retry, never a loop"
      refute plan_path.exist?
      refute options_path.exist?
    end

    # A writer that names one option but stops without its plan is unusable
    # (produce_plan's own bar), so the retry fires — but the ticket is still a
    # single-shape one, and a later well-formed single-option answer must
    # still be shipped with the approach announced.
    def test_retry_after_a_stalled_single_option_still_announces_it
      stalled = "OPTIONS\n1 | Guard the paste | I stop the broken paste and insert plain text. | openproject | small\n"
      @harness = SequencedHarness.new([stalled, SINGLE_OPTION_ANSWER])
      agent    = Agent.new(@ctx, pull: @pull, harness: @harness, publish: @publish)
      inject_worktree(agent, FakeWorktree.new)
      st = agent.send(:state_for, "42", "Fix the bug")

      assert_equal :ok, agent.send(:produce_plan, st, nil, allow_options: true)
      assert_equal 2, @harness.captures.length, "one retry, never a loop"
      assert plan_path.exist?
      assert(@notes.any? { |n| n.include?("This is a straightforward problem") && n.include?("Guard the paste") },
             "allow_options must survive the retry so a later single option is still announced")
    end

    def test_parse_options_skips_junk_and_orders_by_number
      rows = Helpers.parse_options(
                         "OPTIONS\nnonsense\n2 | B | second | openproject | large\n" \
                         "**1** | A | first | openproject | small\n")

      assert_equal [1, 2], rows.map { |o| o["n"] }
      assert_equal "first", rows.first["summary"]
    end

    def test_parse_leading_options_splits_one_option_from_its_plan
      options, remainder = Helpers.parse_leading_options(SINGLE_OPTION_ANSWER)

      assert_equal [1], options.map { |o| o["n"] }
      assert_equal "Guard the paste", options.first["title"]
      assert_equal "## Plan: #42 — Fix the bug", remainder.lines.first.chomp
    end

    def test_parse_leading_options_stops_at_the_last_option_line_when_options_only
      options, remainder = Helpers.parse_leading_options(OPTIONS_ANSWER)

      assert_equal [1, 2], options.map { |o| o["n"] }
      assert_equal "", remainder
    end

    def test_parse_leading_options_does_not_mistake_a_plan_table_for_more_options
      body = "OPTIONS\n1 | Guard the paste | I stop the broken paste. | openproject | small\n\n" \
             "## Plan: #42 — Fix\n| file | change |\n| a.rb | 3 | guard |\n"
      options, remainder = Helpers.parse_leading_options(body)

      assert_equal [1], options.map { |o| o["n"] }
      assert_includes remainder, "| a.rb | 3 | guard |"
    end

    def test_ship_with_a_number_and_trailing_words_keeps_both
      save_options
      @agent.handle(intent(:ship, text: "2 but keep the toast"))

      prompt = @harness.captures.find { |p| p.include?("chose option 2") }
      assert prompt, "a leading number still selects the option"
      assert_includes prompt, "The reporter added: but keep the toast"
    end

    def test_offer_passes_the_option_repos_on_as_the_expected_targets
      save_options
      @agent.handle(intent(:ship, text: "1"))

      prompt = @harness.captures.find { |p| p.include?("chose option 1") }
      assert_includes prompt, "The offer named these repos for it: openproject"
    end

    def test_offer_labels_the_repo_and_size_line_as_an_estimate
      agent_answering(OPTIONS_ANSWER).handle(intent(:ship))
      assert_includes @notes.last, "estimate: openproject"
    end

    # ── an existing prototype ─────────────────────────────────────────────────

    def test_direction_after_shipping_points_at_the_pr_and_plans_nothing
      pr_url_path.write("https://github.com/o/r/pull/1\n")
      plan_path.dirname.mkpath
      plan_path.write("## Plan\nDo it.\n")
      before = plan_path.read

      @agent.handle(intent(:ship, text: "use a toast instead"))

      assert_empty @harness.captures, "a shipped work package must not spend a plan call"
      assert_equal before, plan_path.read, "the plan the PR links must not be rewritten"
      assert_includes @notes.last, "Ask for the change on the pull request"
      assert_includes @notes.last, "https://github.com/o/r/pull/1"
    end

    def test_option_switch_after_shipping_also_points_at_the_pr
      save_options
      pr_url_path.write("https://github.com/o/r/pull/1\n")

      @agent.handle(intent(:ship, text: "2"))

      assert_empty @harness.captures
      assert_includes @notes.last, "pull request"
    end

    # ── ship ──────────────────────────────────────────────────────────────────

    def test_ship_reports_existing_pr_without_reimplementing
      st = @agent.send(:state_for, "42", "Fix the bug")
      pr_url_path.write("https://github.com/o/r/pull/1\n")

      @agent.send(:ship, st)
      assert_empty @harness.runs, "should not implement when already shipped"
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
      refute(@harness.runs.any? { |p| p.include?("APPROVED PLAN") }, "should not re-run implement")
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
      @harness = FakeHarness.new(plan: "REPOS: openproject, ck\n## Plan\nDo it across both.\n")
      @agent  = Agent.new(@ctx, pull: @pull, harness: @harness, publish: @publish)
      inject_worktree(@agent, FakeWorktree.new)

      @agent.handle(intent(:ship))

      items = @ctx.state_dir / "work_packages" / "op.example.com" / "42"
      assert (items / "repos" / "openproject" / "pr_url.txt").exist?, "openproject PR opened"
      assert (items / "repos" / "ck" / "pr_url.txt").exist?, "ck PR opened"
      assert_equal %w[ck openproject], JSON.parse((items / "target_repos.json").read).sort
      refute_includes plan_path.read, "REPOS:", "the REPOS line is stripped from the saved plan"
    end

    def test_plan_without_a_repos_line_falls_back_to_the_default_repo
      @agent.handle(intent(:ship))   # FakeHarness's plan has no REPOS line
      assert pr_url_path.exist?, "ships to the default repo when no REPOS line is given"
    end

    # ── handlers / routing ────────────────────────────────────────────────────

    def test_reply_is_internal_when_trigger_is_internal
      @agent.handle(intent(:ship, internal: true))
      assert_equal [true], @note_visibility
    end

    def test_reply_is_public_when_trigger_is_public
      @agent.handle(intent(:ship, internal: false))
      assert_equal [false], @note_visibility
    end

    def test_reply_defaults_to_internal_when_visibility_unknown
      @agent.handle(intent(:ship, internal: nil))
      assert_equal [true], @note_visibility
    end

    def test_handle_ship_skips_ship_when_needs_info
      @harness = FakeHarness.new(plan: "NEEDS_INFO\n### Questions for the reporter\n- repro?")
      @agent  = Agent.new(@ctx, pull: @pull, harness: @harness, publish: @publish)
      inject_worktree(@agent, FakeWorktree.new)

      @agent.handle(intent(:ship))
      refute pr_url_path.exist?, "must not ship when info is missing"
    end

    # The clone is otherwise wherever the last run left it: `./opilot` fetches
    # each base once at launch and never moves the working tree onto it, and no
    # run checks the tree back off its fix branch. So a long-lived agent loop
    # planned against months-old code, or against an unrelated WP's fix branch.
    def test_planning_syncs_the_clone_to_current_upstream_first
      wt = FakeWorktree.new
      inject_worktree(@agent, wt)

      @agent.handle(intent(:ship))

      assert_includes wt.fetched, ["origin", { ref: "dev" }],
                      "the base must be re-fetched at plan time, not trusted from launch"
      assert_includes wt.checkouts, "origin/dev",
                      "and the tree moved onto it before the LLM reads anything"
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

    def test_handle_ship_threads_one_session_through_plan_and_implement_but_not_pr_description
      @agent.handle(intent(:ship))
      session = @ctx.state_dir / "work_packages" / "op.example.com" / "42" / "session_id"
      assert_equal [session], @harness.capture_sessions.uniq, "plan must use the per-WP session"

      pr_index = @harness.runs.index { |p| p.include?("PR description") }
      refute_nil pr_index, "a PR description pass should run"
      implement_sessions = @harness.run_sessions.each_index.reject { |i| i == pr_index }.map { |i| @harness.run_sessions[i] }
      assert_equal [session], implement_sessions.uniq, "implement must resume the planning session"
      assert_nil @harness.run_sessions[pr_index],
                 "the PR description is a separate, stateless call — not part of the resumed session"
    end

    # A work package planned by an earlier run (when `plan` was its own command)
    # ships on the next trigger, with no approval step left to wait for.
    def test_ship_ships_a_plan_left_by_an_earlier_run
      plan_path.dirname.mkpath
      plan_path.write("## Plan\nDo it.\n")

      @agent.handle(intent(:ship))
      assert pr_url_path.exist?
      assert_empty @harness.captures, "a plan a human has read is built as it reads, never rewritten"
    end

    def test_handle_chat_posts_reply_and_changes_no_files
      @agent.handle(intent(:chat, text: "what about tests?"))
      refute plan_path.exist?
      refute pr_url_path.exist?
      assert_includes @notes, "Here's my take."
    end

    # ── related work packages ─────────────────────────────────────────────────

    def related_path(id = "42"); @ctx.state_dir / "work_packages" / "op.example.com" / id / "related.json"; end

    def test_ship_writes_related_index_and_injects_it
      @pull.related = [{ "id" => "200", "relation" => "relates", "subject" => "Other", "status" => "New" }]
      @agent.handle(intent(:ship))

      assert related_path.exist?, "the related index should be written"
      index = JSON.parse(related_path.read)
      assert_equal "/state/work_packages/op.example.com/200/item.json", index.first["item_path"]

      plan_prompt = @harness.captures.find { |p| p.include?("AVAILABLE REPOS") }
      assert_includes plan_prompt, "RELATED:"
      assert_includes plan_prompt, "/state/work_packages/op.example.com/42/related.json"
    end

    def test_handle_chat_injects_related_context
      @pull.related = [{ "id" => "50", "relation" => "parent", "subject" => "Epic", "status" => "New" }]
      @agent.handle(intent(:chat, text: "how does this relate to the epic?"))

      chat_prompt = @harness.runs.find { |p| p.include?("You are opilot") }
      assert_includes chat_prompt, "RELATED:"
    end

    def test_no_related_means_no_index_and_no_related_line
      @agent.handle(intent(:ship))   # FakePull.related defaults to []
      refute related_path.exist?
      plan_prompt = @harness.captures.find { |p| p.include?("AVAILABLE REPOS") }
      refute_includes plan_prompt, "RELATED:"
    end

    def test_handle_and_ack_marks_but_posts_no_note_on_error
      agent = Agent.new(@ctx, pull: @pull, harness: @harness, publish: BoomPublish.new)
      inject_worktree(agent, FakeWorktree.new)
      plan_path.dirname.mkpath
      plan_path.write("## Plan\nDo it.\n")   # approve will reach the failing push

      agent.send(:handle_and_ack, intent(:ship, user: "Jane", user_href: "/api/v3/users/2"))

      # Acked despite the failure → no infinite re-try on the next poll.
      assert_equal [["42", "2024-02-01T00:00:00Z"]], @pull.acted
      # A handled error is logged, not posted — no error note left on the WP.
      refute(@notes.any? { |n| n.include?("hit an error") }, "must not post an error note on the WP")
      refute pr_url_path.exist?
    end

    # ── create wp ───────────────────────────────────────────────────────────
    #
    # Every assertion here guards one fact: a work package cannot be deleted.

    OP = "https://op.example.com/api/v3".freeze

    def allow_users(*ids); @ctx.allowed_op_user_ids = ids.map(&:to_s); end

    def created_wps_path(id = "42")
      @ctx.state_dir / "work_packages" / "op.example.com" / id / "created_wps.json"
    end

    def created_wps(id = "42")
      created_wps_path(id).exist? ? JSON.parse(created_wps_path(id).read) : []
    end

    # The four requests a create walks through. `project_links` empty models a
    # token without :add_work_packages.
    def stub_create_wp(project_links: { "createWorkPackage" => { "href" => "/x" } },
                       types: [{ "id" => 5, "name" => "Feature" }],
                       create_status: 201, relation_status: 201,
                       form_status: 200, validation_errors: {})
      stub_request(:get, "#{OP}/work_packages/42")
        .to_return(status: 200, body: JSON.generate(
          "id" => 42, "_links" => { "project" => { "href" => "/api/v3/projects/7" } }
        ))
      stub_request(:get, "#{OP}/projects/7")
        .to_return(status: 200, body: JSON.generate("name" => "Demo", "_links" => project_links))
      stub_request(:get, "#{OP}/projects/7/types")
        .to_return(status: 200, body: JSON.generate("_embedded" => { "elements" => types }))
      # The preflight. The real endpoint answers 200 even for a payload it
      # rejects — validation errors are its normal output.
      @form_requests = []
      stub_request(:post, "#{OP}/work_packages/form").to_return do |req|
        @form_requests << JSON.parse(req.body)
        { status: form_status,
          body: JSON.generate("_type" => "Form",
                              "_embedded" => { "validationErrors" => validation_errors }) }
      end
      @create_requests = []
      stub_request(:post, "#{OP}/work_packages?notify=false").to_return do |req|
        @create_requests << JSON.parse(req.body)
        { status: create_status,
          body: JSON.generate("id" => 99, "displayId" => "99", "subject" => "Split the login toast out") }
      end
      @relation_requests = []
      stub_request(:post, "#{OP}/work_packages/99/relations?notify=false").to_return do |req|
        @relation_requests << JSON.parse(req.body)
        { status: relation_status, body: "{}" }
      end
    end

    def test_create_wp_is_off_without_an_allowlist_and_says_so_once
      stub_create_wp
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal 1, @notes.length
      assert_includes @notes.last, "OPILOT_ALLOWED_OP_USER_IDS"
      assert_empty @harness.runs, "no LLM call before the allowlist is checked"
      assert_empty @create_requests, "and nothing is created"

      # A second ask adds no second note: with no allowlist, anyone could
      # otherwise fill the activity tab by repeating the trigger.
      @agent.handle(intent(:create_wp, text: "again", comment_at: "2024-02-02T00:00:00Z"))
      assert_equal 1, @notes.length
    end

    def test_create_wp_creates_relates_and_reports_the_link
      allow_users(2)
      stub_create_wp
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      payload = @create_requests.fetch(0)
      assert_equal "Split the login toast out", payload["subject"]
      assert_equal "/api/v3/projects/7", payload.dig("_links", "project", "href")
      assert_equal "/api/v3/types/5", payload.dig("_links", "type", "href"), "the drafted type name resolved"
      assert_includes payload.dig("description", "raw"), "/work_packages/42",
                      "the description backlinks the source, so the origin survives a failed relation"

      # The relation runs from the NEW work package, with numeric ids on both sides.
      assert_equal [{ "type" => "relates",
                      "_links" => { "to" => { "href" => "/api/v3/work_packages/42" } } }],
                   @relation_requests

      record = created_wps.fetch(0)
      assert_equal "2024-02-01T00:00:00Z", record["comment_at"]
      assert_equal "99", record["id"]
      assert record["related"]

      assert_includes @notes.last, "/work_packages/99"
      refute_includes @notes.last, "@opilot",
                      "a reply naming @opilot would make opilot read its own comment as a trigger"
    end

    def test_create_wp_is_idempotent_on_the_trigger_comment
      allow_users(2)
      stub_create_wp
      trigger = intent(:create_wp, text: "for Rosanna's suggestion")
      @agent.handle(trigger)
      @agent.handle(trigger)   # a re-fired trigger — a crash before the ack, say

      assert_equal 1, @create_requests.length, "one request, one work package — it can never be deleted"
      assert_equal 1, @relation_requests.length, "and the recorded relation is not posted twice either"
      assert_equal 1, created_wps.length
      assert_includes @notes.last, "I already created"
    end

    # The writer narrates before it answers, whatever the prompt says — so the
    # draft is what follows the last DRAFT: marker, and the deliberation above it
    # is scratch. The first version of this prompt demanded SUBJECT: on line 1 and
    # a real run burned its whole output limit getting ready to comply.
    def test_create_wp_reads_the_draft_after_the_marker_and_discards_the_narration
      allow_users(2)
      stub_create_wp
      narrated = "Let me think. Is this really a bug? SUBJECT: a decoy in my notes\n" \
                 "I will go with the reporter's wording.\n\nDRAFT:\n" \
                 "SUBJECT: The real subject\nTYPE: Feature\n\nThe real body.\n"
      agent = Agent.new(@ctx, pull: @pull, publish: @publish, harness: FakeHarness.new(draft: narrated))
      agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      payload = @create_requests.fetch(0)
      assert_equal "The real subject", payload["subject"], "not the decoy above the marker"
      assert_includes payload.dig("description", "raw"), "The real body."
      refute_includes payload.dig("description", "raw"), "Let me think"
    end

    def test_create_wp_reads_needs_info_after_the_marker_too
      allow_users(2)
      stub_create_wp
      agent = Agent.new(@ctx, pull: @pull, publish: @publish,
                        harness: FakeHarness.new(draft: "Thinking about it.\n\nDRAFT:\nNEEDS_INFO\nWhich one?\n"))
      agent.handle(intent(:create_wp, text: "for the suggestion"))

      assert_includes @notes.last, "Which one?"
      assert_empty @create_requests
    end

    # A model that spends its whole output limit deliberating stops with
    # `error_length` and returns nothing. The reader is waiting, so say that
    # plainly rather than showing them the subtype.
    def test_create_wp_explains_an_output_limit_instead_of_showing_error_length
      allow_users(2)
      stub_create_wp
      boom = Class.new(FakeHarness) do
        def run(prompt, **) = prompt.include?("create a NEW work package") ? raise(Harness::Error, "error_length") : super
      end.new
      agent = Agent.new(@ctx, pull: @pull, publish: @publish, harness: boom)
      agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_includes @notes.last, "ran out of writing space"
      refute_includes @notes.last, "error_length", "the subtype belongs in the log, not the thread"
      assert_empty @create_requests
    end

    def test_create_wp_needs_info_asks_and_creates_nothing
      allow_users(2)
      stub_create_wp
      agent = Agent.new(@ctx, pull: @pull, publish: @publish,
                        harness: FakeHarness.new(draft: "NEEDS_INFO\nWhich suggestion? I see three.\n"))
      agent.handle(intent(:create_wp, text: "for the suggestion"))

      assert_includes @notes.last, "Which suggestion?"
      assert_empty @create_requests
      assert_empty created_wps
    end

    def test_create_wp_retries_an_unusable_draft_once_then_gives_up
      allow_users(2)
      stub_create_wp
      harness = SequencedDraftHarness.new(["I think we should do this.", "still no subject line"])
      agent = Agent.new(@ctx, pull: @pull, publish: @publish, harness: harness)
      agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal 2, harness.runs.length, "one retry, then stop"
      assert_empty @create_requests
      assert_includes @notes.last, "could not draft"
    end

    def test_create_wp_retry_that_answers_properly_creates_it
      allow_users(2)
      stub_create_wp
      harness = SequencedDraftHarness.new(["no fields here", "SUBJECT: A real one\n\nBody.\n"])
      agent = Agent.new(@ctx, pull: @pull, publish: @publish, harness: harness)
      agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal "A real one", @create_requests.fetch(0)["subject"]
    end

    # A drafted type name the project does not have falls back to the project's
    # first type, NAMED in the payload. The API would pick its own default anyway,
    # but a schema is per project and type, so a type nobody stated is a payload
    # validated against something nobody chose — and `op wp create` requires one
    # for the same reason.
    def test_create_wp_names_a_fallback_type_when_the_draft_names_an_unknown_one
      allow_users(2)
      stub_create_wp(types: [{ "id" => 8, "name" => "Bug" }])
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal "/api/v3/types/8", @create_requests.fetch(0).dig("_links", "type", "href")
    end

    # Unless the type list could not be read at all — then the API's default beats
    # no work package.
    def test_create_wp_omits_the_type_only_when_no_type_is_known
      allow_users(2)
      stub_create_wp(types: [])
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      refute @create_requests.fetch(0)["_links"].key?("type")
    end

    def test_create_wp_refuses_without_the_add_work_packages_permission
      allow_users(2)
      stub_create_wp(project_links: {})
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_includes @notes.last, "add_work_packages"
      assert_empty @harness.runs, "the preflight runs before the LLM call, not after it"
      assert_empty @create_requests
    end

    def test_create_wp_with_no_request_asks_what_to_create
      allow_users(2)
      stub_create_wp
      @agent.handle(intent(:create_wp, text: ""))

      assert_includes @notes.last, "Tell me what to create"
      assert_empty @harness.runs
      assert_empty @create_requests
    end

    def test_create_wp_reports_a_failed_relation_and_retries_it_next_time
      allow_users(2)
      stub_create_wp(relation_status: 403)
      trigger = intent(:create_wp, text: "for Rosanna's suggestion")
      @agent.handle(trigger)

      assert_includes @notes.last, "could not link"
      refute created_wps.fetch(0)["related"], "recorded as unlinked, so a later run can finish it"

      # The work package stands; only the link is missing — so the next ask
      # relates it instead of creating a second one.
      stub_request(:post, "#{OP}/work_packages/99/relations?notify=false").to_return(status: 201, body: "{}")
      @agent.handle(trigger)
      assert_equal 1, @create_requests.length
      assert created_wps.fetch(0)["related"]
    end

    # A project can REQUIRE custom fields, and required-ness is per project and
    # type. Without the preflight this ends as a 422 in the log, after an LLM call
    # has been spent, with the reader told nothing.
    def test_create_wp_names_the_required_fields_it_must_not_invent
      allow_users(2)
      stub_create_wp(
        types: [{ "id" => 5, "name" => "Feature" }, { "id" => 8, "name" => "Bug" }],
        validation_errors: {
          "customField205" => { "message" => "Cécile List Type Multi Select Custom Field can't be blank." },
          "customField223" => { "message" => "Cécile Hierarchy SingleSelect Required CF can't be blank." }
        }
      )
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal 1, @form_requests.length, "the payload is checked before it is written"
      assert_empty @create_requests, "nothing is created, and no value is guessed"
      assert_empty created_wps

      note = @notes.last
      assert_includes note, "Cécile List Type Multi Select Custom Field can't be blank.",
                      "the instance's own wording, not a paraphrase"
      assert_includes note, "customField223"
      assert_includes note, "Feature, Bug", "required-ness is per type, so name the alternatives"
    end

    def test_create_wp_preflights_before_every_create
      allow_users(2)
      stub_create_wp
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal 1, @form_requests.length
      assert_equal @form_requests.fetch(0), @create_requests.fetch(0),
                   "the same payload is sent on unchanged — the form applies no defaults the create won't"
    end

    # A form that answers something else about itself (403, an HTML proxy error)
    # is not an answer about the payload, so it must not block the create.
    def test_create_wp_creates_anyway_when_the_form_endpoint_is_unavailable
      allow_users(2)
      stub_create_wp(form_status: 403)
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_equal 1, @create_requests.length
      assert_includes @notes.last, "/work_packages/99"
    end

    def test_create_wp_reports_a_failed_create
      allow_users(2)
      stub_create_wp(create_status: 422)
      @agent.handle(intent(:create_wp, text: "for Rosanna's suggestion"))

      assert_includes @notes.last, "HTTP 422"
      assert_empty created_wps
    end

    def test_chat_offers_create_wp_only_when_it_is_available
      @agent.handle(intent(:chat, text: "what can you do?"))
      refute_includes @harness.runs.last, "create wp", "never offer a command that would be refused"

      allow_users(2)
      @agent.handle(intent(:chat, text: "what can you do?"))
      assert_includes @harness.runs.last, "@opilot create wp"
    end

    def test_replies_mention_the_requesting_user
      @agent.handle(intent(:ship, user: "Jane Doe", user_href: "/api/v3/users/2"))
      note = @notes.last
      assert_includes note, %q(<mention class="mention" data-id="2" data-type="user" data-text="Jane Doe">@Jane Doe</mention>)
      assert_includes note, "https://github.com/o/r/pull/7"
    end
  end
end
