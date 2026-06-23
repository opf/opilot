require_relative "../test_helper"
require "tmpdir"
require "stringio"

module Chomper
  class BacklogRunnerTest < Minitest::Test
    FILTERS = FilterSet.new(project_ids: ["STC"], type_ids: ["1"], status_ids: ["1"],
                            version_ids: [], scan_from_at: nil)

    class FakePull
      def initialize(items = nil, saved: FILTERS, single: nil, singles: nil)
        @items = items; @saved = saved; @single = single; @singles = singles
      end

      def saved_backlog_filters; @saved; end
      def load_or_prompt_backlog_filters; FILTERS; end
      # singles maps an id to its item (or nil for "not found"); single is the
      # id-agnostic fallback used by the single-WP tests.
      def fetch_single_item(wp_id); @singles ? @singles[wp_id] : @single; end

      def fetch_all_items(_filters, module_field_key: nil)
        raise "unexpected fetch_all_items call" if @items.nil?
        @items
      end
    end

    # Answers every triage batch with a fixed complexity per item id.
    class FakeTriageClaude
      def initialize(map); @map = map; end

      def run(_prompt, tools: nil, model: nil, session_file: nil)
        rows = @map.map { |id, cx| %({"id": "#{id}", "complexity": "#{cx}"}) }
        "---BEGIN JSON---\n[#{rows.join(",")}]\n---END JSON---\n"
      end
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
    class NoGitRunner < BacklogRunner
      private def checkout_branch(_st); end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = Struct.new(
        :script_dir, :state_dir, :op_url, :token, :worktree_container, :state_container,
        :repo_path, :log_file, :progress_file, :auto_plan_approval
      ) do
        def auto_plan_approval?; auto_plan_approval; end   # auto-approve plans (off by default)
      end.new(
        Pathname(@tmpdir), Pathname(@tmpdir) / ".chomper", "https://op.example.com", "tok",
        "/repo", "/state", Pathname(@tmpdir),
        Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt", false
      )
      @ctx.state_dir.mkpath

      # WP schema for the filtered type carries the Module custom field.
      stub_request(:get, "https://op.example.com/api/v3/work_packages/schemas/STC-1")
        .to_return(status: 200, body: JSON.generate(
          "_type"          => "Schema",
          "customField429" => { "type" => "[]CustomField::Hierarchy::Item", "name" => "Module" }
        ))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
      super
    end

    def item(id, subject, mod)
      { "id" => id.to_s, "subject" => subject, "module" => mod,
        "url" => "https://op.example.com/wp/#{id}", "description" => "" }
    end

    # The on-disk item cache `show` renders from when the triage cache is valid.
    def write_item(id, subject, mod)
      data = item(id, subject, mod)
      dir = @ctx.state_dir / "items" / id.to_s
      dir.mkpath
      (dir / "item.json").write(JSON.generate(data))
      data
    end

    def seed_triage(map, module_field: "customField429", item_ids: map.keys)
      (@ctx.state_dir / "backlog_triage.json").write(JSON.generate(
        "created_at"         => "2026-06-09T00:00:00Z",
        "filter_fingerprint" => "STC|1|1|",
        "module_field"       => module_field,
        "item_ids"           => item_ids,
        "complexity"         => map
      ))
    end

    def runner(items = nil)
      BacklogRunner.new(@ctx, pull: FakePull.new(items), claude: nil, publish: nil)
    end

    def with_stdin(text)
      old = $stdin
      $stdin = StringIO.new(text)
      yield
    ensure
      $stdin = old
    end

    def test_input_prompts_ring_the_terminal_bell
      r = runner([])
      out, _err = capture_io { with_stdin("s\n") { r.send(:prompt_approval, "42") } }
      assert_includes out, "\a", "the approval prompt should ring the bell"
      assert_includes out, "\e]9;chomper: plan for #42 ready for review\e\\",
                      "the approval prompt should post an OSC 9 notification naming the WP"
    end

    def test_auto_plan_approval_skips_the_prompt
      @ctx.auto_plan_approval = true
      r = runner([])
      verdict = nil
      # $stdin untouched: auto-approval must not read a keystroke.
      capture_io { verdict = r.send(:prompt_approval, "42") }
      assert_equal :approve, verdict
    end

    def test_show_orders_clusters_and_marks_prior_outcomes
      write_item(1, "Costs item", "Costs")
      write_item(2, "No module easy", "")
      write_item(3, "No module hard", "")
      write_item(4, "Shipped one", "Costs")
      write_item(5, "Activities easy", "Activities")
      seed_triage({ "1" => "moderate", "2" => "trivial", "3" => "complex",
                    "4" => "simple", "5" => "trivial" })
      (@ctx.state_dir / "items" / "4" / "pr_url.txt").write("https://github.com/o/r/pull/9")

      # FakePull has no items: show must render offline, from the caches alone.
      out, = capture_io { runner.show }

      assert_includes out, "trivial · (unassigned) (1 item)"
      assert_includes out, "simple · Costs (1 item)"

      assert out.index("#2") < out.index("#5"), "(unassigned) before Activities within the trivial tier"
      assert out.index("#5") < out.index("#4"), "all trivial before simple"
      assert out.index("#4") < out.index("#1"), "simple before moderate"
      assert out.index("#1") < out.index("#3"), "moderate before complex"

      assert_includes out, "[1/5]"
      assert_includes out, "[trivial]"
      assert_includes out, "↩ finished"
      assert_includes out, "https://op.example.com/wp/1"
      assert_includes out, "4 to process, 1 shipped, 0 dropped"
    end

    def test_show_marks_dropped_items
      write_item(5, "Dropped one", "Costs")
      seed_triage({ "5" => "simple" })
      (@ctx.state_dir / "items" / "5" / "backlog_done.txt").write("dropped")

      out, = capture_io { runner.show }

      assert_includes out, "↩ dropped"
      assert_includes out, "0 to process, 0 shipped, 1 dropped"
    end

    def test_show_without_cache_declined_triage_shows_unknown_complexity
      items = [item(1, "A thing", "Costs")]

      out, = with_stdin("n\n") { capture_io { runner(items).show } }

      assert_includes out, "Run triage now?"
      assert_includes out, "[?]"
      refute (@ctx.state_dir / "backlog_triage.json").exist?, "declined triage must not write a cache"
    end

    def test_triage_classifies_and_saves_cache
      items = [item(1, "Easy", "Costs"), item(2, "Hard", "")]
      claude = FakeTriageClaude.new("1" => "trivial", "2" => "complex")
      runner = BacklogRunner.new(@ctx, pull: FakePull.new(items), claude: claude, publish: nil)

      out, = capture_io { runner.triage }

      assert_includes out, "Triage complete: 1 trivial, 1 complex."
      cache = JSON.parse((@ctx.state_dir / "backlog_triage.json").read)
      assert_equal "STC|1|1|", cache["filter_fingerprint"]
      assert_equal "customField429", cache["module_field"]
      assert_equal %w[1 2], cache["item_ids"]
      assert_equal({ "1" => "trivial", "2" => "complex" }, cache["complexity"])
    end

    def test_show_with_valid_cache_makes_no_api_calls
      write_item(1, "A thing", "Costs")
      seed_triage({ "1" => "trivial" })

      # Other tests legitimately hit the schema endpoint; only requests made
      # from here on must count for the assert_not_requested below.
      WebMock.reset_executed_requests!

      # $stdin untouched and FakePull empty: any prompt or fetch would raise.
      out, = capture_io { runner.show }

      refute_includes out, "Reuse cached complexity?"
      assert_includes out, "[trivial]"
      assert_not_requested :get, "https://op.example.com/api/v3/work_packages/schemas/STC-1"
    end

    def test_process_fails_without_saved_filters
      r = BacklogRunner.new(@ctx, pull: FakePull.new(nil, saved: nil), claude: nil, publish: nil)
      err = assert_raises(Chomper::FatalError) { r.process }
      assert_match(/backlog triage/, err.message)
    end

    def test_process_fails_without_cached_queue
      err = assert_raises(Chomper::FatalError) { capture_io { runner.process } }
      assert_match(/no cached queue/, err.message)
      assert_match(/backlog triage/, err.message)
    end

    def test_process_walks_cached_queue_and_skips_prior_outcomes
      write_item(4, "Shipped one", "Costs")
      seed_triage({ "4" => "simple" })
      (@ctx.state_dir / "items" / "4" / "pr_url.txt").write("https://github.com/o/r/pull/9")

      # FakePull has no items and claude is nil: only the offline path may run,
      # and the sole item is skipped before any planning.
      out, = capture_io { runner.process }

      assert_includes out, "↩ finished — skipping"
      assert_includes out, "Backlog run complete."
    end

    def test_process_replan_rewrites_plan_with_typed_feedback
      write_item(6, "Replannable", "Costs")
      seed_triage({ "6" => "simple" })
      (@ctx.state_dir / "items" / "6" / "plan.md").write("## Original plan")
      claude = FakePlanClaude.new
      r = BacklogRunner.new(@ctx, pull: FakePull.new, claude: claude, publish: nil)

      # Existing plan.md skips initial generation; [r] re-plans, then [s] skips.
      out, = with_stdin("r\nuse a rake task instead\ns\n") { capture_io { r.process } }

      assert_equal 1, claude.prompts.size
      assert_includes claude.prompts.first, "use a rake task instead"
      assert_includes claude.prompts.first, "EXISTING PLAN"
      assert_equal "## Revised plan", (@ctx.state_dir / "items" / "6" / "plan.md").read
      assert_includes out, "skipped"
    end

    def test_process_replan_empty_feedback_uses_chat_context
      write_item(7, "Replannable", "Costs")
      seed_triage({ "7" => "simple" })
      (@ctx.state_dir / "items" / "7" / "plan.md").write("## Original plan")
      claude = FakePlanClaude.new
      r = BacklogRunner.new(@ctx, pull: FakePull.new, claude: claude, publish: nil)

      capture_io { with_stdin("r\n\ns\n") { r.process } }

      assert_includes claude.prompts.first, "preceding conversation"
    end

    def test_process_skip_persists_marker_and_keeps_plan
      write_item(8, "Skippable", "Costs")
      seed_triage({ "8" => "simple" })
      (@ctx.state_dir / "items" / "8" / "plan.md").write("## A plan")

      # Existing plan.md: no claude needed; [s] must persist the outcome.
      out, = with_stdin("s\n") { capture_io { runner.process } }

      assert_includes out, "parked until the next triage"
      assert_equal "skipped", (@ctx.state_dir / "items" / "8" / "backlog_done.txt").read
      assert (@ctx.state_dir / "items" / "8" / "plan.md").exist?, "skip must keep the plan for later"
    end

    def test_process_recovers_when_generation_returns_no_plan
      write_item(15, "Flaky plan", "Costs")
      seed_triage({ "15" => "simple" })
      claude = ScriptedPlanClaude.new("Let me look at the issue.", "## Plan: #15 — Flaky plan")
      r = NoGitRunner.new(@ctx, pull: FakePull.new, claude: claude, publish: nil)

      # First generation streams only preamble: recovery prompt, [r]etry
      # regenerates a real plan, then [s]kip at the approval prompt.
      out, = with_stdin("r\ns\n") { capture_io { r.process } }

      assert_includes out, "Plan generation failed"
      assert_includes out, "[r]etry"
      assert_equal "## Plan: #15 — Flaky plan",
                   (@ctx.state_dir / "items" / "15" / "plan.md").read
      assert_includes out, "parked until the next triage"
    end

    def test_process_recovers_when_claude_run_dies
      write_item(16, "Dead run", "Costs")
      seed_triage({ "16" => "simple" })
      claude = ScriptedPlanClaude.new(:error)
      r = NoGitRunner.new(@ctx, pull: FakePull.new, claude: claude, publish: nil)

      out, = with_stdin("d\n") { capture_io { r.process } }

      assert_includes out, "Plan generation failed"
      assert_equal "dropped", (@ctx.state_dir / "items" / "16" / "backlog_done.txt").read
      refute (@ctx.state_dir / "items" / "16" / "plan.md").exist?
    end

    def test_process_replan_failure_keeps_previous_plan
      write_item(17, "Replan dies", "Costs")
      seed_triage({ "17" => "simple" })
      (@ctx.state_dir / "items" / "17" / "plan.md").write("## Plan: original")
      claude = ScriptedPlanClaude.new(:error)
      r = BacklogRunner.new(@ctx, pull: FakePull.new, claude: claude, publish: nil)

      # [r]e-plan with feedback dies; the old plan survives and the approval
      # prompt returns, where [s]kip parks the item.
      out, = with_stdin("r\nmake it simpler\ns\n") { capture_io { r.process } }

      refute_includes out, "Plan generation failed"
      assert_equal "## Plan: original", (@ctx.state_dir / "items" / "17" / "plan.md").read
      assert_includes out, "parked until the next triage"
    end

    def test_plan_plans_a_fresh_wp_and_stops_without_shipping
      write_item(20, "Plannable", "Costs")
      seed_triage({ "20" => "simple" })
      claude = FakePlanClaude.new
      r = NoGitRunner.new(@ctx, pull: FakePull.new, claude: claude, publish: nil)

      # No plan.md yet: claude generates one, [y] accepts it without shipping.
      out, = with_stdin("y\n") { capture_io { r.plan } }

      assert_includes out, "[y]es accept plan", "approval prompt reflects plan-only mode"
      assert_includes out, "plan approved"
      assert_equal "## Revised plan", (@ctx.state_dir / "items" / "20" / "plan.md").read
      refute (@ctx.state_dir / "items" / "20" / "pr_url.txt").exist?, "plan must not ship"
      refute (@ctx.state_dir / "items" / "20" / "backlog_done.txt").exist?,
             "plan leaves the WP processable later"
    end

    def test_plan_silently_skips_wps_that_already_have_a_plan
      write_item(21, "Distinctive Subject", "Costs")
      seed_triage({ "21" => "simple" })
      (@ctx.state_dir / "items" / "21" / "plan.md").write("## A plan")

      # An existing plan means this WP is done for the plan pass: no prompt, no
      # claude, and — unlike process/run — no per-item line, so a re-run of
      # `backlog plan` doesn't dump the (mostly-planned) queue.
      out, = capture_io { runner.plan }

      refute_includes out, "accept plan", "must not prompt for an already-planned WP"
      refute_includes out, "Distinctive Subject", "plan mode stays quiet about already-planned WPs"
      assert_includes out, "Backlog run complete."
      assert (@ctx.state_dir / "items" / "21" / "plan.md").exist?, "the existing plan is kept"
    end

    def test_plan_fails_without_cached_queue
      err = assert_raises(Chomper::FatalError) { capture_io { runner.plan } }
      assert_match(/no cached queue/, err.message)
    end

    def test_plan_ids_plans_a_live_wp_without_shipping
      claude = FakePlanClaude.new
      single = item(5, "By id", "Costs")
      r = NoGitRunner.new(@ctx, pull: FakePull.new(singles: { "5" => single }), claude: claude, publish: nil)

      out, = with_stdin("y\n") { capture_io { r.plan_ids("5") } }

      assert_equal "## Revised plan", (@ctx.state_dir / "items" / "5" / "plan.md").read
      refute (@ctx.state_dir / "items" / "5" / "pr_url.txt").exist?, "plan must not ship"
      assert_includes out, "plan approved"
    end

    def test_show_marks_wps_that_already_have_a_plan
      write_item(22, "Drafted", "Costs")
      seed_triage({ "22" => "simple" })
      (@ctx.state_dir / "items" / "22" / "plan.md").write("## A plan")

      out, = capture_io { runner.show }

      assert_includes out, "planned"
      assert_includes out, "1 planned"
      assert_includes out, "1 to process", "a drafted plan still counts as to-process until shipped"
    end

    def test_show_counts_skipped_separately
      write_item(9, "Parked one", "Costs")
      seed_triage({ "9" => "simple" })
      (@ctx.state_dir / "items" / "9" / "backlog_done.txt").write("skipped")

      out, = capture_io { runner.show }

      assert_includes out, "↩ skipped"
      assert_includes out, "0 to process, 0 shipped, 0 dropped, 1 skipped"
    end

    def test_triage_clears_skipped_but_not_dropped
      items = [item(10, "Was skipped", "Costs"), item(11, "Was dropped", "Costs")]
      skipped_marker = @ctx.state_dir / "items" / "10" / "backlog_done.txt"
      dropped_marker = @ctx.state_dir / "items" / "11" / "backlog_done.txt"
      [skipped_marker, dropped_marker].each { |f| f.dirname.mkpath }
      skipped_marker.write("skipped")
      dropped_marker.write("dropped")
      claude = FakeTriageClaude.new("10" => "simple", "11" => "simple")
      r = BacklogRunner.new(@ctx, pull: FakePull.new(items), claude: claude, publish: nil)

      capture_io { r.triage }

      refute skipped_marker.exist?, "a fresh triage must clear skip markers"
      assert_equal "dropped", dropped_marker.read, "drop markers must survive a re-triage"
    end

    def test_run_respects_skip_markers
      items = [item(14, "Parked one", "Costs")]
      seed_triage({ "14" => "simple" })
      marker = @ctx.state_dir / "items" / "14" / "backlog_done.txt"
      marker.dirname.mkpath
      marker.write("skipped")

      # "\n" accepts the cached-triage reuse prompt; the only item is skipped,
      # so the walk never needs claude or further stdin.
      out, = with_stdin("\n") { capture_io { runner(items).run } }

      assert_includes out, "↩ skipped — skipping"
      assert_equal "skipped", marker.read, "a plain backlog run must not clear skip markers"
    end

    def test_backlog_skip_marks_item_and_refuses_shipped
      write_item(12, "Park me", "Costs")
      write_item(13, "Shipped one", "Costs")
      (@ctx.state_dir / "items" / "13" / "pr_url.txt").write("https://github.com/o/r/pull/9")

      out, = capture_io { runner.skip("12") }
      assert_includes out, "Park me"
      assert_equal "skipped", (@ctx.state_dir / "items" / "12" / "backlog_done.txt").read

      out, = capture_io { runner.skip("13") }
      assert_includes out, "already shipped: https://github.com/o/r/pull/9"
      refute (@ctx.state_dir / "items" / "13" / "backlog_done.txt").exist?

      assert_raises(Chomper::FatalError) { capture_io { runner.skip("abc") } }
    end

    def test_fix_fails_when_wp_cannot_be_fetched
      err = assert_raises(Chomper::FatalError) { capture_io { runner.fix("999") } }
      assert_match(/could not fetch work package #999/, err.message)
    end

    def test_fix_reports_already_shipped
      data = write_item(4, "Shipped one", "Costs")
      (@ctx.state_dir / "items" / "4" / "pr_url.txt").write("https://github.com/o/r/pull/9")
      r = BacklogRunner.new(@ctx, pull: FakePull.new(single: data), claude: nil, publish: nil)

      out, = capture_io { r.fix("4") }

      assert_includes out, "Already shipped: https://github.com/o/r/pull/9"
    end

    # With several ids a fetch failure on one is logged, not fatal, and the
    # remaining ids still run. Both items here resolve without Claude (one
    # missing, one already shipped) so the walk completes without an agent.
    def test_fix_with_multiple_ids_continues_past_a_fetch_failure
      shipped = write_item(7, "Shipped one", "Costs")
      (@ctx.state_dir / "items" / "7" / "pr_url.txt").write("https://github.com/o/r/pull/9")
      pull = FakePull.new(singles: { "999" => nil, "7" => shipped })
      r = BacklogRunner.new(@ctx, pull: pull, claude: nil, publish: nil)

      out, = capture_io { r.fix("999", "7") }

      assert_match(/could not fetch work package #999/, out)
      assert_includes out, "Already shipped: https://github.com/o/r/pull/9"
    end

    def test_show_falls_back_to_fetch_when_cache_has_no_item_ids
      items = [item(1, "A thing", "Costs")]
      seed_triage({ "1" => "trivial" }, item_ids: nil)

      out, = capture_io { runner(items).show }

      assert_includes out, "[trivial]"
      assert_includes out, "Fetching work packages"
    end
  end
end
