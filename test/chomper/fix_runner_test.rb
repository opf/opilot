require_relative "../test_helper"
require "tmpdir"
require "stringio"

module Chomper
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
    class FakePlanClaude
      attr_reader :prompts

      def initialize; @prompts = []; end

      def capture(prompt, tools: nil, model: nil, outfile:, session_file: nil)
        @prompts << prompt
        Pathname(outfile).write("## Revised plan")
      end
    end

    # Plays back one scripted outcome per capture call: a string is written to
    # the outfile, :error raises like a run that died mid-way (no outfile write).
    class ScriptedPlanClaude
      def initialize(*outputs); @outputs = outputs; end

      def capture(_prompt, tools: nil, model: nil, outfile:, session_file: nil)
        out = @outputs.shift or raise "unexpected capture call"
        raise Claude::Error, "run died" if out == :error
        Pathname(outfile).write(out)
      end
    end

    # The initial-plan path checks out a branch first; stub out git so the
    # plan-failure recovery flow can be exercised without a worktree.
    class NoGitRunner < FixRunner
      private def checkout_branch(_st, _repo); end
    end

    # A runner whose fix branch already carries commits, so the build/ship
    # paths can run without a worktree or a Claude implementation pass.
    class PrebuiltRunner < FixRunner
      private def checkout_branch(_st, _repo); end
      private def branch_has_commits?(_st, _repo); true; end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      state_dir = Pathname(@tmpdir) / ".chomper"
      state_dir.mkpath
      registry = Registry.build(script_dir: Pathname(@tmpdir), state_dir: state_dir, op_repo_path: @tmpdir)
      @ctx = Struct.new(
        :script_dir, :state_dir, :op_url, :token, :state_container,
        :log_file, :progress_file, :auto_plan_approval, :repos
      ) do
        def auto_plan_approval?; auto_plan_approval; end   # auto-approve plans (off by default)
        def default_repo; repos.default; end
        def op_host; "op.example.com"; end                 # WP mirror namespace (derived from op_url)
      end.new(
        Pathname(@tmpdir), state_dir, "https://op.example.com", "tok",
        "/state",
        Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt", false, registry
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

    def runner(single: nil, singles: nil, claude: nil)
      FixRunner.new(@ctx, pull: FakePull.new(single: single, singles: singles), claude: claude, publish: nil)
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
      assert_includes out, "\e]9;chomper: plan for #42 ready for review\e\\",
                      "the approval prompt should post an OSC 9 notification naming the WP"
    end

    def test_auto_plan_approval_skips_the_prompt
      @ctx.auto_plan_approval = true
      r = runner
      verdict = nil
      # $stdin untouched: auto-approval must not read a keystroke.
      capture_io { verdict = r.send(:prompt_approval, "42") }
      assert_equal :approve, verdict
    end

    def test_ship_fails_when_wp_cannot_be_fetched
      err = assert_raises(Chomper::FatalError) { capture_io { runner(single: nil).ship_ids("999") } }
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
    # remaining ids still run. Both items here resolve without Claude (one
    # missing, one already shipped) so the run completes without an agent.
    def test_ship_with_multiple_ids_continues_past_a_fetch_failure
      shipped = write_item(7, "Shipped one")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "7" / "pr_url.txt").write("https://github.com/o/r/pull/9")
      r = runner(singles: { "999" => nil, "7" => shipped })

      out, = capture_io { r.ship_ids("999", "7") }

      assert_match(/could not fetch work package #999/, out)
      assert_includes out, "Already shipped: https://github.com/o/r/pull/9"
    end

    # publish: nil doubles as the assertion — any attempt to open a PR from the
    # build path would crash on the nil publisher.
    def test_build_ids_commits_locally_without_publishing
      claude = FakePlanClaude.new
      r = PrebuiltRunner.new(@ctx, pull: FakePull.new(singles: { "8" => item(8, "Buildable") }),
                             claude: claude, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.build_ids("8") } }

      assert_includes out, "[y]es build", "approval prompt reflects build mode"
      assert_includes out, "✓ Built task/8-buildable (openproject)"
      assert_includes out, "ship it with `./chomper ship 8`"
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "8" / "repos" / "openproject" / "pr_url.txt").exist?,
             "build must not ship"
    end

    def test_build_ids_reports_an_already_shipped_wp
      claude = FakePlanClaude.new
      pr_dir = @ctx.state_dir / "work_packages" / "op.example.com" / "9" / "repos" / "openproject"
      pr_dir.mkpath
      (pr_dir / "pr_url.txt").write("https://github.com/o/r/pull/12")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "9" / "plan.md").write("## Plan: done")
      r = PrebuiltRunner.new(@ctx, pull: FakePull.new(singles: { "9" => item(9, "Done one") }),
                             claude: claude, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.build_ids("9") } }

      assert_includes out, "Already shipped (openproject): https://github.com/o/r/pull/12"
      refute_includes out, "✓ Built", "a shipped WP is not rebuilt"
    end

    def test_plan_ids_plans_a_live_wp_and_stops_without_shipping
      claude = FakePlanClaude.new
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "5" => item(5, "By id") }), claude: claude, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.plan_ids("5") } }

      assert_includes out, "[y]es accept plan", "approval prompt reflects plan-only mode"
      assert_includes out, "plan approved"
      assert_equal "## Revised plan", (@ctx.state_dir / "work_packages" / "op.example.com" / "5" / "plan.md").read
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "5" / "pr_url.txt").exist?, "plan must not ship"
    end

    def test_plan_ids_injects_related_context_when_present
      claude = FakePlanClaude.new
      pull = FakePull.new(singles: { "23" => item(23, "Plannable") })
      pull.related = [{ "id" => "200", "relation" => "relates", "subject" => "Other", "status" => "New" }]
      r = FixRunner.new(@ctx, pull: pull, claude: claude, publish: nil)

      with_stdin("y\n") { capture_io { r.plan_ids("23") } }

      assert_includes claude.prompts.first, "RELATED:", "the plan prompt should carry related-WP context"
      assert (@ctx.state_dir / "work_packages" / "op.example.com" / "23" / "related.json").exist?, "the related index should be written"
    end

    def test_plan_ids_recovers_when_generation_returns_no_plan
      claude = ScriptedPlanClaude.new("Let me look at the issue.", "## Plan: #15 — Flaky plan")
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "15" => item(15, "Flaky plan") }), claude: claude, publish: nil)

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
      claude = ScriptedPlanClaude.new(:error)
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "16" => item(16, "Dead run") }), claude: claude, publish: nil)

      out, = with_stdin("d\n") { capture_io { r.plan_ids("16") } }

      assert_includes out, "Plan generation failed"
      assert_includes out, "dropped"
      refute (@ctx.state_dir / "work_packages" / "op.example.com" / "16" / "plan.md").exist?
    end

    def test_replan_rewrites_plan_with_typed_feedback
      write_item(6, "Replannable")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "6" / "plan.md").write("## Original plan")
      claude = FakePlanClaude.new
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "6" => item(6, "Replannable") }), claude: claude, publish: nil)

      # Existing plan.md skips initial generation; [r] re-plans, then [s] skips.
      out, = with_stdin("r\nuse a rake task instead\ns\n") { capture_io { r.plan_ids("6") } }

      assert_equal 1, claude.prompts.size
      assert_includes claude.prompts.first, "use a rake task instead"
      assert_includes claude.prompts.first, "EXISTING PLAN"
      assert_equal "## Revised plan", (@ctx.state_dir / "work_packages" / "op.example.com" / "6" / "plan.md").read
      assert_includes out, "skipped"
    end

    def test_replan_empty_feedback_uses_chat_context
      write_item(7, "Replannable")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "7" / "plan.md").write("## Original plan")
      claude = FakePlanClaude.new
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "7" => item(7, "Replannable") }), claude: claude, publish: nil)

      capture_io { with_stdin("r\n\ns\n") { r.plan_ids("7") } }

      assert_includes claude.prompts.first, "preceding conversation"
    end

    def test_replan_failure_keeps_previous_plan
      write_item(17, "Replan dies")
      (@ctx.state_dir / "work_packages" / "op.example.com" / "17" / "plan.md").write("## Plan: original")
      claude = ScriptedPlanClaude.new(:error)
      r = FixRunner.new(@ctx, pull: FakePull.new(singles: { "17" => item(17, "Replan dies") }), claude: claude, publish: nil)

      # [r]e-plan with feedback dies; the old plan survives and the approval
      # prompt returns, where [s]kip ends the WP.
      out, = with_stdin("r\nmake it simpler\ns\n") { capture_io { r.plan_ids("17") } }

      refute_includes out, "Plan generation failed"
      assert_equal "## Plan: original", (@ctx.state_dir / "work_packages" / "op.example.com" / "17" / "plan.md").read
      assert_includes out, "skipped"
    end
  end
end
