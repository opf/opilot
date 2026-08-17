require_relative "../test_helper"
require "tmpdir"
require "stringio"

module OPilot
  class FixRunnerTest < Minitest::Test
    class FakePull
      attr_accessor :related
      def initialize(single: nil, singles: nil)
        @single = single; @singles = singles; @related = []
      end

      # singles maps an id to its item (or nil for "not found"); single is the
      # id-agnostic fallback used by the single-WP tests.
      def fetch_single_item(wp_id); @singles ? @singles[wp_id] : @single; end

      def related_work_packages(_id); @related; end
    end

    # Records every capture prompt and writes a fixed plan to the outfile,
    # standing in for the (re-)plan path of process_item.
    class FakePlanHarness
      attr_reader :prompts

      def initialize; @prompts = []; end

      def capture(prompt, tools: nil, model: nil, outfile:, session_file: nil)
        @prompts << prompt
        Pathname(outfile).write("## Revised plan")
      end
    end

    # Plays back one scripted outcome per capture call: a string is written to
    # the outfile, :error raises like a run that died mid-way (no outfile write).
    class ScriptedPlanHarness
      def initialize(*outputs); @outputs = outputs; end

      def capture(_prompt, tools: nil, model: nil, outfile:, session_file: nil)
        out = @outputs.shift or raise "unexpected capture call"
        raise Harness::Error, "run died" if out == :error
        Pathname(outfile).write(out)
      end
    end

    # The initial-plan path checks out a branch first; stub out git so the
    # plan-failure recovery flow can be exercised without a worktree.
    class NoGitRunner < FixRunner
      private def checkout_branch(_st, _repo); end
    end

    # A runner whose fix branch already carries commits, so the build/ship
    # paths can run without a worktree or an LLM implementation pass.
    class PrebuiltRunner < FixRunner
      private def checkout_branch(_st, _repo); end
      private def branch_has_commits?(_st, _repo); true; end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      state_dir = Pathname(@tmpdir) / ".opilot"
      state_dir.mkpath
      registry = Registry.build(script_dir: Pathname(@tmpdir), state_dir: state_dir, op_repo_path: @tmpdir)
      @ctx = Struct.new(
        :script_dir, :state_dir, :op_url, :token, :state_container,
        :log_file, :progress_file, :repos,
        :contributor_token
      ) do
        def default_repo; repos.default; end
        def op_host; "op.example.com"; end                 # WP mirror namespace (derived from op_url)
      end.new(
        Pathname(@tmpdir), state_dir, "https://op.example.com", "tok",
        "/state",
        Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt", registry,
        # A contributor token, because `ship` now refuses without one — as it must,
        # since it ends in a push. The token-less cases are tested explicitly below.
        "contributor-tok"
      )
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
      super
    end

    def item(id, subject)
      { "id" => id.to_s, "subject" => subject,
        "url" => "https://op.example.com/wp/#{id}", "description" => "" }
    end

    def write_item(id, subject)
      data = item(id, subject)
      dir = @ctx.state_dir / "work_packages" / "op.example.com" / id.to_s
      dir.mkpath
      (dir / "item.json").write(JSON.generate(data))
      data
    end

    def runner(single: nil, singles: nil, harness: nil)
      FixRunner.new(@ctx, pull: FakePull.new(single: single, singles: singles), harness: harness, publish: nil)
    end

    def with_stdin(text)
      old = $stdin
      $stdin = StringIO.new(text)
      yield
    ensure
      $stdin = old
    end

    def test_input_prompts_ring_the_terminal_bell
      r = runner
      out, _err = capture_io { with_stdin("s\n") { r.send(:prompt_approval, "42") } }
      assert_includes out, "\a", "the approval prompt should ring the bell"
      assert_includes out, "\e]9;opilot: plan for #42 ready for review\e\\",
                      "the approval prompt should post an OSC 9 notification naming the WP"
    end

    # --- the publishing identity ------------------------------------------

    def test_ship_refuses_before_any_claude_work_without_a_token
      # Publish#open_pr reported this at the very END, after a full plan and
      # implement run. `pr` has always checked up front; ship now does too.
      @ctx.contributor_token = nil
      err = assert_raises(OPilot::FatalError) { capture_io { runner.ship_ids("42") } }
      assert_match(/set GITHUB_CONTRIBUTOR_TOKEN in \.env to ship/, err.message)
      assert_match(/build.*plan.*need no token/, err.message)
    end

    def test_build_and_plan_still_work_without_a_token
      # They stop before publishing, so requiring one would be gratuitous.
      @ctx.contributor_token = nil
      data = write_item(7, "Local only")
      # Skipped at the approval prompt: what matters is that neither command
      # refused before getting there.
      %i[build_ids plan_ids].each do |mode|
        run = NoGitRunner.new(@ctx, pull: FakePull.new(single: data), harness: FakePlanHarness.new)
        capture_io { with_stdin("s\n") { run.public_send(mode, "7") } }
      end
    end

    def test_ship_publishes_as_the_contributor_bot
      # There is one publishing identity, and `ship` uses it like every other
      # mode: the fix branch goes to the bot's fork, never to a canonical repo.
      publish = FixRunner.new(@ctx, pull: FakePull.new, harness: nil).instance_variable_get(:@publish)
      assert_equal "contributor-tok", publish.author_token
      assert_equal "GITHUB_CONTRIBUTOR_TOKEN", publish.token_env_var
    end

    def test_ship_fails_when_wp_cannot_be_fetched
      err = assert_raises(OPilot::FatalError) { capture_io { runner(single: nil).ship_ids("999") } }
      assert_match(/could not fetch work package #999/, err.message)
    end

    def test_ship_reports_already_shipped
      data = write_item(4, "Shipped one")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "4" / "pr_url.txt").write("https://github.com/o/r/pull/9")
      r = runner(single: data)

      out, = capture_io { r.ship_ids("4") }

      assert_includes out, "Already shipped: https://github.com/o/r/pull/9"
    end

    # With several ids a fetch failure on one is logged, not fatal, and the
    # remaining ids still run. Both items here resolve without the LLM (one
    # missing, one already shipped) so the run completes without an agent.
    def test_ship_with_multiple_ids_continues_past_a_fetch_failure
      shipped = write_item(7, "Shipped one")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "7" / "pr_url.txt").write("https://github.com/o/r/pull/9")
      r = runner(singles: { "999" => nil, "7" => shipped })

      out, = capture_io { r.ship_ids("999", "7") }

      assert_match(/could not fetch work package #999/, out)
      assert_includes out, "Already shipped: https://github.com/o/r/pull/9"
    end

    def test_build_ids_commits_locally_without_publishing
      harness = FakePlanHarness.new
      r = PrebuiltRunner.new(@ctx, pull: FakePull.new(singles: { "8" => item(8, "Buildable") }),
                             harness: harness, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.build_ids("8") } }

      assert_includes out, "[y]es build", "approval prompt reflects build mode"
      assert_includes out, "✓ Built task/8-buildable (openproject)"
      assert_includes out, "ship it with `./opilot wp ship 8`"
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "8" / "repos" / "openproject" / "pr_url.txt").exist?,
             "build must not ship"
    end

    def test_build_ids_reports_an_already_shipped_wp
      harness = FakePlanHarness.new
      pr_dir = @ctx.state_dir / "work_packages" / "op.example.com" / "9" / "repos" / "openproject"
      pr_dir.mkpath
      (pr_dir / "pr_url.txt").write("https://github.com/o/r/pull/12")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "9" / "plan.md").write("## Plan: done")
      r = PrebuiltRunner.new(@ctx, pull: FakePull.new(singles: { "9" => item(9, "Done one") }),
                             harness: harness, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.build_ids("9") } }

      assert_includes out, "Already shipped (openproject): https://github.com/o/r/pull/12"
      refute_includes out, "✓ Built", "a shipped WP is not rebuilt"
    end

    def test_plan_ids_plans_a_live_wp_and_stops_without_shipping
      harness = FakePlanHarness.new
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "5" => item(5, "By id") }), harness: harness, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.plan_ids("5") } }

      assert_includes out, "[y]es accept plan", "approval prompt reflects plan-only mode"
      assert_includes out, "plan approved"
      assert_equal "## Revised plan", (@ctx.state_dir / "work_packages" / "op.example.com" / "5" / "plan.md").read
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "5" / "pr_url.txt").exist?, "plan must not ship"
    end

    def test_plan_ids_injects_related_context_when_present
      harness = FakePlanHarness.new
      pull = FakePull.new(singles: { "23" => item(23, "Plannable") })
      pull.related = [{ "id" => "200", "relation" => "relates", "subject" => "Other", "status" => "New" }]
      r = FixRunner.new(@ctx, pull: pull, harness: harness, publish: nil)

      with_stdin("y\n") { capture_io { r.plan_ids("23") } }

      assert_includes harness.prompts.first, "RELATED:", "the plan prompt should carry related-WP context"
      assert (@ctx.state_dir / "work_packages" / "op.example.com" / "23" / "related.json").exist?, "the related index should be written"
    end

    def test_plan_ids_recovers_when_generation_returns_no_plan
      harness = ScriptedPlanHarness.new("Let me look at the issue.", "## Plan: #15 — Flaky plan")
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "15" => item(15, "Flaky plan") }), harness: harness, publish: nil)

      # First generation streams only preamble: recovery prompt, [r]etry
      # regenerates a real plan, then [s]kip at the approval prompt.
      out, = with_stdin("r\ns\n") { capture_io { r.plan_ids("15") } }

      assert_includes out, "Plan generation failed"
      assert_includes out, "[r]etry"
      assert_equal "## Plan: #15 — Flaky plan",
                   (@ctx.state_dir / "work_packages" / "op.example.com" / "15" / "plan.md").read
      assert_includes out, "skipped"
    end

    def test_plan_ids_recovers_when_claude_run_dies
      harness = ScriptedPlanHarness.new(:error)
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "16" => item(16, "Dead run") }), harness: harness, publish: nil)

      out, = with_stdin("d\n") { capture_io { r.plan_ids("16") } }

      assert_includes out, "Plan generation failed"
      assert_includes out, "dropped"
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "16" / "plan.md").exist?
    end

    # ── implementation options at the console ────────────────────────────────

    OPTIONS_ANSWER = <<~TEXT
      OPTIONS
      1 | Guard the paste | I insert plain text and show a message. | openproject | small
      2 | Rebuild the editor | I rebuild the bundled editor. | openproject | large
    TEXT

    def test_plan_ids_offers_options_then_plans_the_chosen_one
      harness = ScriptedPlanHarness.new(OPTIONS_ANSWER, "## Plan: #31 — chosen")
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "31" => item(31, "Two ways") }),
                        harness: harness, publish: nil)

      # Options are offered, [2] is chosen, then [s]kip at the approval prompt.
      out, = with_stdin("2\ns\n") { capture_io { r.plan_ids("31") } }

      assert_includes out, "This fix has more than one shape"
      assert_includes out, "Rebuild the editor"
      assert_includes out, "estimate: openproject"
      assert_equal "## Plan: #31 — chosen",
                   (@ctx.state_dir / "work_packages" / "op.example.com" / "31" / "plan.md").read
    end

    # No real choice to offer: the writer names the one approach and keeps
    # going into its plan in the same response. Nothing to ask — it goes
    # straight to the normal approval prompt, on the plan the response left.
    SINGLE_OPTION_ANSWER = <<~TEXT
      OPTIONS
      1 | Guard the paste | I insert plain text and show a message. | openproject | small

      ## Plan: #35 — Fix the bug
      REPOS: openproject
      ### Files to change
      ### Approach
      ### Tests to run
      ### Risks / assumptions
    TEXT

    def test_plan_ids_accepts_one_named_approach_without_re_asking
      harness = ScriptedPlanHarness.new(SINGLE_OPTION_ANSWER)
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "35" => item(35, "One way") }),
                        harness: harness, publish: nil)

      out, = with_stdin("s\n") { capture_io { r.plan_ids("35") } }

      refute_includes out, "This fix has more than one shape"
      plan = (@ctx.state_dir / "work_packages" / "op.example.com" / "35" / "plan.md").read
      refute_includes plan, "OPTIONS", "the header must not leak into the saved plan"
      assert_includes plan, "## Plan: #35 — Fix the bug"
    end

    def test_option_prompt_passes_the_choice_into_the_plan_call
      harness = ScriptedPlanHarness.new(OPTIONS_ANSWER, "## Plan: #32 — chosen")
      captured = []
      harness.define_singleton_method(:capture) do |prompt, **kwargs|
        captured << prompt
        out = @outputs.shift or raise "unexpected capture call"
        Pathname(kwargs[:outfile]).write(out)
      end
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "32" => item(32, "Two ways") }),
                        harness: harness, publish: nil)

      with_stdin("1 but keep the toast\ns\n") { capture_io { r.plan_ids("32") } }

      assert_includes captured.first, "Before the plan, always name the approach", "the first call may ask"
      assert_includes captured.last, "chose option 1"
      assert_includes captured.last, "The reporter added: but keep the toast"
      refute_includes captured.last, "Before the plan, always name the approach", "the second call must not ask again"
    end

    def test_option_prompt_accepts_free_direction_instead_of_a_number
      harness = ScriptedPlanHarness.new(OPTIONS_ANSWER, "## Plan: #33 — own way")
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "33" => item(33, "Two ways") }),
                        harness: harness, publish: nil)

      out, = with_stdin("do it with a rake task\ns\n") { capture_io { r.plan_ids("33") } }

      assert_equal "## Plan: #33 — own way",
                   (@ctx.state_dir / "work_packages" / "op.example.com" / "33" / "plan.md").read
      assert_includes out, "skipped"
    end

    def test_option_prompt_can_drop_the_work_package
      harness = ScriptedPlanHarness.new(OPTIONS_ANSWER)
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "34" => item(34, "Two ways") }),
                        harness: harness, publish: nil)

      out, = with_stdin("d\n") { capture_io { r.plan_ids("34") } }

      assert_includes out, "dropped"
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "34" / "plan.md").exist?
    end

    def test_replan_rewrites_plan_with_typed_feedback
      write_item(6, "Replannable")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "6" / "plan.md").write("## Original plan")
      harness = FakePlanHarness.new
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "6" => item(6, "Replannable") }), harness: harness, publish: nil)

      # Existing plan.md skips initial generation; [r] re-plans, then [s] skips.
      out, = with_stdin("r\nuse a rake task instead\ns\n") { capture_io { r.plan_ids("6") } }

      assert_equal 1, harness.prompts.size
      assert_includes harness.prompts.first, "use a rake task instead"
      assert_includes harness.prompts.first, "EXISTING PLAN"
      assert_equal "## Revised plan", (@ctx.state_dir / "work_packages" / "op.example.com" / "6" / "plan.md").read
      assert_includes out, "skipped"
    end

    def test_replan_empty_feedback_uses_chat_context
      write_item(7, "Replannable")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "7" / "plan.md").write("## Original plan")
      harness = FakePlanHarness.new
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "7" => item(7, "Replannable") }), harness: harness, publish: nil)

      capture_io { with_stdin("r\n\ns\n") { r.plan_ids("7") } }

      assert_includes harness.prompts.first, "preceding conversation"
    end

    def test_replan_failure_keeps_previous_plan
      write_item(17, "Replan dies")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "17" / "plan.md").write("## Plan: original")
      harness = ScriptedPlanHarness.new(:error)
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "17" => item(17, "Replan dies") }), harness: harness, publish: nil)

      # [r]e-plan with feedback dies; the old plan survives and the approval
      # prompt returns, where [s]kip ends the WP.
      out, = with_stdin("r\nmake it simpler\ns\n") { capture_io { r.plan_ids("17") } }

      refute_includes out, "Plan generation failed"
      assert_equal "## Plan: original", (@ctx.state_dir / "work_packages" / "op.example.com" / "17" / "plan.md").read
      assert_includes out, "skipped"
    end
  end
end
