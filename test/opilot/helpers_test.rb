require_relative "../test_helper"
require "git"

module OPilot
  class HelpersTest < Minitest::Test
    class Host
      include Helpers
      def initialize
        @ctx = Struct.new(:log_file, :script_dir).new(
          Pathname("/dev/null"),
          Pathname("/tmp")
        )
      end
    end

    def h = @h ||= Host.new

    def test_strip_ansi_removes_color_codes
      assert_equal "red text", h.strip_ansi("\e[31mred text\e[0m")
    end

    def test_guarded_tick_swallows_errors_so_the_loop_survives
      ran = false
      # An uncaught error in a poll must not propagate out of the loop.
      h.guarded_tick("test") { raise "boom" }
      h.guarded_tick("test") { ran = true }   # loop keeps going on the next tick
      assert ran
    end

    def test_guarded_tick_returns_block_value_on_success
      assert_equal 42, h.guarded_tick("test") { 42 }
    end

    def test_guarded_tick_lets_system_exit_escape_so_ctrl_c_ends_the_loop
      # Ctrl-C exits via SystemExit (raised by the trap in bin/opilot); it is
      # not a StandardError, so the backstop must not swallow it.
      assert_raises(SystemExit) { h.guarded_tick("test") { raise SystemExit }; }
    end

    def test_wp_label_prefixes_numeric_ids_only
      assert_equal "#59942",   h.wp_label("59942")
      assert_equal "STC-162",  h.wp_label("STC-162")
      assert_equal "#42",      Helpers.wp_label(42)
    end

    # ── parse_work_packages (Prompts.create_wp's answer) ────────────────────

    def block(subject, type: "Feature", body: "Rosanna asked for it.")
      type_line = type ? "TYPE: #{type}\n" : ""
      "BEGIN WORK PACKAGE\nSUBJECT: #{subject}\n#{type_line}\n#{body}\nEND WORK PACKAGE\n"
    end

    def test_parse_work_packages_reads_the_subject_type_and_description
      drafts = Helpers.parse_work_packages(block("Add a toast"))
      assert_equal 1, drafts.length
      assert_equal "Add a toast", drafts[0]["subject"]
      assert_equal "Feature",     drafts[0]["type"]
      assert_equal "Rosanna asked for it.", drafts[0]["description"]
    end

    def test_parse_work_packages_type_is_optional
      drafts = Helpers.parse_work_packages(block("Add a toast", type: nil, body: "Body."))
      assert_equal "Add a toast", drafts[0]["subject"]
      assert_equal "", drafts[0]["type"]
      assert_equal "Body.", drafts[0]["description"]
    end

    def test_parse_work_packages_tolerates_blank_lines_and_case
      drafts = Helpers.parse_work_packages(
        "\n\nBEGIN WORK PACKAGE\n\nsubject: Add a toast\ntype: Bug\n\nBody.\nEND WORK PACKAGE"
      )
      assert_equal "Add a toast", drafts[0]["subject"]
      assert_equal "Bug", drafts[0]["type"]
    end

    # Whether an offshoot is a child of the source or a peer beside it is stated
    # per block, and never inferred. A child changes the source's own dates and
    # progress, so an absent or unrecognised value is the reversible one.
    def test_parse_work_packages_reads_the_link_line
      drafts = Helpers.parse_work_packages(
        "BEGIN WORK PACKAGE\nSUBJECT: A subtask\nTYPE: Task\nLINK: child\n\nBody.\nEND WORK PACKAGE"
      )
      assert_equal "child", drafts[0]["link"]
    end

    def test_parse_work_packages_link_defaults_to_related
      assert_equal "related", Helpers.parse_work_packages(block("No link line"))[0]["link"]
      odd = "BEGIN WORK PACKAGE\nSUBJECT: A\nLINK: subtask-ish\n\nBody.\nEND WORK PACKAGE"
      assert_equal "related", Helpers.parse_work_packages(odd)[0]["link"],
                   "an unrecognised value is not a licence to re-parent"
    end

    # TYPE and LINK are both optional, and losing one the writer did state would
    # be worse than reading them in either order.
    def test_parse_work_packages_reads_type_and_link_in_either_order
      drafts = Helpers.parse_work_packages(
        "BEGIN WORK PACKAGE\nSUBJECT: A\nlink: CHILD\ntype: Bug\n\nBody.\nEND WORK PACKAGE"
      )
      assert_equal "child", drafts[0]["link"]
      assert_equal "Bug",   drafts[0]["type"]
      assert_equal "Body.", drafts[0]["description"]
    end

    # SUBJECT is a header line like the other two, not a position. A writer that
    # puts TYPE first has still said everything, and a retry call is the cost.
    def test_parse_work_packages_reads_the_subject_below_the_other_header_lines
      drafts = Helpers.parse_work_packages(
        "BEGIN WORK PACKAGE\nTYPE: Main Bug\nLINK: child\nSUBJECT: A\n\nBody.\nEND WORK PACKAGE"
      )
      assert_equal "A",        drafts[0]["subject"]
      assert_equal "Main Bug", drafts[0]["type"]
      assert_equal "child",    drafts[0]["link"]
      assert_equal "Body.",    drafts[0]["description"]
    end

    # A SUBJECT below the header is description text, not the subject.
    def test_parse_work_packages_does_not_reach_past_the_header_for_a_subject
      assert_empty Helpers.parse_work_packages(
        "BEGIN WORK PACKAGE\nTYPE: Task\n\nSUBJECT: A\nEND WORK PACKAGE"
      )
    end

    # Each block is one work package, in order.
    def test_parse_work_packages_reads_several_blocks
      drafts = Helpers.parse_work_packages(
        "Here they are.\n#{block("First", type: "Feature")}\nand then\n#{block("Second", type: "Task")}"
      )
      assert_equal %w[First Second], drafts.map { |d| d["subject"] }
      assert_equal %w[Feature Task], drafts.map { |d| d["type"] }
    end

    # No block, no subject, no closing marker: none is a usable answer. The
    # caller must never POST a work package it could not read — one cannot be
    # deleted.
    def test_parse_work_packages_without_a_usable_block_is_empty
      assert_empty Helpers.parse_work_packages("I think we should add a toast.")
      assert_empty Helpers.parse_work_packages("SUBJECT: Add a toast\n\nBody.")
      assert_empty Helpers.parse_work_packages(block("").sub("SUBJECT: \n", "SUBJECT:\n"))
      assert_empty Helpers.parse_work_packages("")
    end

    # An unclosed block means the answer was CUT OFF — every block shares one
    # output budget. The whole answer goes, so no half-written description is
    # created as a work package.
    def test_parse_work_packages_rejects_a_cut_off_answer
      cut = "#{block("Complete one")}BEGIN WORK PACKAGE\nSUBJECT: Half of one\nTYPE: Task\n\nThe body sto"
      assert_empty Helpers.parse_work_packages(cut)
      assert_empty Helpers.parse_work_packages("BEGIN WORK PACKAGE\nSUBJECT: A\n\nBody.\n#{block("B")}")
      assert_empty Helpers.parse_work_packages("SUBJECT: A\n\nBody.\nEND WORK PACKAGE\n")
    end

    # Only the LEADING lines are fields, so a description discussing its own
    # "SUBJECT:" line cannot move the subject.
    def test_parse_work_packages_ignores_field_lines_inside_the_description
      drafts = Helpers.parse_work_packages(
        block("The real one", body: "Write SUBJECT: something else on line 1.")
      )
      assert_equal "The real one", drafts[0]["subject"]
      assert_includes drafts[0]["description"], "SUBJECT: something else"
    end

    # A description quotes the thread, and somebody will paste opilot's own
    # answer into a comment — so a marker inside a fence is text.
    def test_parse_work_packages_ignores_markers_inside_a_fence
      quoted = "Christoph pasted this:\n\n```\nEND WORK PACKAGE\nBEGIN WORK PACKAGE\nSUBJECT: decoy\n```\n\nThat is the bug."
      drafts = Helpers.parse_work_packages(block("The real one", body: quoted))
      assert_equal 1, drafts.length
      assert_equal "The real one", drafts[0]["subject"]
      assert_includes drafts[0]["description"], "SUBJECT: decoy"
    end

    def test_after_marker_takes_the_last_marked_section
      text = "thinking\nDRAFT:\nfirst try\nDRAFT:\nthe real one"
      assert_equal "the real one", Helpers.after_marker(text, "DRAFT")
    end

    def test_after_marker_returns_the_whole_text_when_the_marker_is_absent
      assert_equal "SUBJECT: x", Helpers.after_marker("SUBJECT: x", "DRAFT")
    end

    # Anchored to the line end, so prose mentioning the marker inline cannot
    # split the answer.
    def test_after_marker_ignores_an_inline_mention_of_the_marker
      text = "I will write DRAFT: below.\nDRAFT:\nthe answer"
      assert_equal "the answer", Helpers.after_marker(text, "DRAFT")
    end

    def test_create_wp_allowed_reads_the_projects_own_links
      assert Helpers.create_wp_allowed?("_links" => { "createWorkPackage" => { "href" => "/x" } })
      assert Helpers.create_wp_allowed?("_links" => { "createWorkPackageImmediately" => { "href" => "/x" } })
      refute Helpers.create_wp_allowed?("_links" => { "self" => { "href" => "/x" } })
      refute Helpers.create_wp_allowed?({})
      refute Helpers.create_wp_allowed?(nil)
    end

    def test_display_id_prefers_the_semantic_id
      assert_equal "PROJ-12", Helpers.display_id("id" => 12, "displayId" => "PROJ-12")
      assert_equal "12",      Helpers.display_id("id" => 12, "displayId" => "")
      assert_equal "12",      Helpers.display_id("id" => 12)
    end

    def test_adopt_github_author_sets_git_identity_from_the_bot
      Helpers.instance_variable_set(:@github_author_adopted, nil)
      stub_request(:get, "https://api.github.com/user").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("login" => "opilot-bot", "id" => 7, "name" => "OPilot Bot")
      )
      keys = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL]
      saved = keys.to_h { |k| [k, ENV[k]] }
      begin
        Helpers.adopt_github_author!("tok")
        assert_equal "OPilot Bot", ENV["GIT_AUTHOR_NAME"]
        assert_equal "7+opilot-bot@users.noreply.github.com", ENV["GIT_AUTHOR_EMAIL"]
        assert_equal "OPilot Bot", ENV["GIT_COMMITTER_NAME"]
        assert_equal "7+opilot-bot@users.noreply.github.com", ENV["GIT_COMMITTER_EMAIL"]
      ensure
        saved.each { |k, v| ENV[k] = v }
        Helpers.instance_variable_set(:@github_author_adopted, nil)
      end
    end

    def test_adopt_github_author_is_a_noop_without_a_token
      Helpers.instance_variable_set(:@github_author_adopted, nil)
      # No WebMock stub: if it tried to reach GitHub, the request would raise.
      Helpers.adopt_github_author!(nil)
    ensure
      Helpers.instance_variable_set(:@github_author_adopted, nil)
    end

    def test_extract_reply_drops_everything_before_the_marker
      raw = "I couldn't fetch PR #127 — no web access.\n\nHere's my honest reply:\n\nREPLY:\nWhat #128 does: wraps toModel.\n"
      assert_equal "What #128 does: wraps toModel.", Helpers.extract_reply(raw)
    end

    def test_extract_reply_accepts_same_line_content_and_takes_the_last_marker
      assert_equal "final", Helpers.extract_reply("REPLY: draft\nmore thinking\nREPLY: final")
    end

    def test_extract_reply_without_a_marker_returns_the_whole_text_stripped
      assert_equal "just the answer", Helpers.extract_reply("  just the answer\n")
      assert_equal "", Helpers.extract_reply(nil)
    end

    def test_strip_ansi_passthrough_plain_string
      assert_equal "plain text", h.strip_ansi("plain text")
    end

    def test_strip_ansi_empty_string
      assert_equal "", h.strip_ansi("")
    end

    def test_branch_slug_basic
      assert_equal "bug/42-fix-the-login-bug", h.branch_slug(42, "Bug", "Fix the login bug")
    end

    def test_branch_slug_downcases
      assert_equal "feature/1-all-caps", h.branch_slug(1, "Feature", "ALL CAPS")
    end

    def test_branch_slug_sanitizes_type
      assert_equal "new-feature/1-title", h.branch_slug(1, "New Feature", "title")
    end

    def test_branch_slug_ampersand_in_type
      assert_equal "research-and-development/1-title", h.branch_slug(1, "Research & Development", "title")
    end

    def test_branch_slug_falls_back_to_task_when_type_empty
      assert_match(/^task\//, h.branch_slug(1, "", "title"))
    end

    def test_branch_slug_replaces_special_chars_with_hyphens
      slug = h.branch_slug(1, "Bug", "Fix: the #1 bug (critical!)")
      refute_match(/[^a-z0-9\-\/]/, slug)
    end

    def test_branch_slug_truncates_title_to_40_chars
      slug = h.branch_slug(1, "Bug", "a" * 60)
      title_part = slug.sub("bug/1-", "")
      assert title_part.length <= 40
    end

    def test_branch_slug_integer_id
      assert_match(/^bug\/99-/, h.branch_slug(99, "Bug", "Some title"))
    end

    def test_branch_slug_string_id
      assert_match(/^bug\/ABC-123-/, h.branch_slug("ABC-123", "Bug", "Some title"))
    end

    # parse_scan_from returns an ISO8601 cutoff `seconds_ago` before now.
    def assert_scan_from(seconds_ago, input)
      parsed = Time.parse(Helpers.parse_scan_from(input))
      assert_in_delta (Time.now.utc - seconds_ago), parsed, 5,
                      "#{input.inspect} should resolve to ~#{seconds_ago}s ago"
    end

    def test_parse_scan_from_blank_and_now_mean_now
      assert_scan_from(0, "")
      assert_scan_from(0, "now")
    end

    def test_parse_scan_from_minutes_hours_days_weeks
      assert_scan_from(60,        "1m")
      assert_scan_from(120,       "2 mins")
      assert_scan_from(3 * 3600,  "3h")
      assert_scan_from(2 * 86400, "2 days")
      assert_scan_from(604800,    "1 week")
    end

    def test_parse_scan_from_months_and_years
      assert_scan_from(2592000,     "1 month")
      assert_scan_from(2 * 2592000, "2 months")
      assert_scan_from(2592000,     "1mo")
      assert_scan_from(31536000,    "1 year")
    end

    def test_parse_scan_from_unparseable_defaults_to_now
      out, = capture_io { assert_scan_from(0, "next tuesday-ish") }
      assert_match(/Could not parse/, out)
    end

    # ── per-WP base branch overrides (REPOS: <name>@<base>) ───────────────────

    # A registry-backed host so record_chosen_repos / state_for / base_for can
    # resolve real Repo objects against a two-repo registry.
    class RepoHost
      include Helpers
      attr_reader :ctx
      def initialize(ctx); @ctx = ctx; end
      # private in Helpers
      public :state_for, :record_chosen_repos, :checkout_branch, :sync_base!, :sync_bases_for_reading
    end

    # The clone check lives in #worktree because that is the funnel every git
    # operation goes through — a check each command had to remember would be
    # forgotten. `./opilot` only WARNS when a clone fails, so this state is
    # reachable, and Git.open's own "path does not exist" names neither the repo
    # nor the fix.
    def test_a_missing_clone_is_reported_with_the_repo_and_the_fix
      host = repo_host
      error = assert_raises(OPilot::FatalError) { host.send(:worktree, host.ctx.default_repo) }

      assert_match(/No git clone for openproject/, error.message)
      assert_match(/Run `\.\/opilot`/, error.message)
      assert_match(/repos\.json/, error.message, "the usual cause is a wrong base branch")
    end

    def test_a_directory_without_git_is_still_a_missing_clone
      host = repo_host
      host.ctx.default_repo.worktree_host.mkpath   # provisioned halfway, no .git
      assert_raises(OPilot::FatalError) { host.send(:worktree, host.ctx.default_repo) }
    end

    FakeStatus = Struct.new(:changed, :added, :deleted)

    class FakeWorktree
      attr_reader :checkouts, :fetched, :configs, :cleans, :resets
      # `dirty` stands in for an implement run that died after the LLM wrote files
      # but before Helpers#commit swept them up; `fetch_error` for an unreachable
      # origin. Both are cases sync_base! must not act on. `leftover` is what
      # `git clean --dry-run` reports: an EARLIER work package's untracked file.
      def initialize(dirty: false, fetch_error: nil, read_refs_error: nil, branch_exists: false, leftover: nil)
        @checkouts = []; @fetched = []; @configs = []; @cleans = []; @resets = []
        @dirty = dirty; @fetch_error = fetch_error; @read_refs_error = read_refs_error
        @branch_exists = branch_exists; @leftover = leftover
      end
      def revparse(_ref)
        return "abc123" if @branch_exists
        raise Git::FailedError.allocate # branch doesn't exist yet
      end
      def clean(**opts)
        @cleans << opts
        opts[:dry_run] && @leftover ? "Would remove #{@leftover}\n" : ""
      end
      def reset(target, **opts); @resets << [target, opts]; end
      def checkout(branch, **opts); @checkouts << [branch, opts]; end
      def fetch(remote, **opts)
        raise @fetch_error if @fetch_error
        # Fails only the tags/release fetch, which #fetch_read_refs must swallow.
        raise @read_refs_error if @read_refs_error && opts[:tags]
        @fetched << [remote, opts]
      end
      def config_set(k, v); @configs << [k, v]; end
      def status
        @dirty ? FakeStatus.new({ "app/x.rb" => :mod }, {}, {}) : FakeStatus.new({}, {}, {})
      end
    end

    def repo_host
      @repo_tmpdir = Dir.mktmpdir
      script_dir = Pathname(@repo_tmpdir)
      state_dir  = script_dir / ".opilot"
      state_dir.mkpath
      (script_dir / "repos.json").write(JSON.generate(
        "summary" => "",
        "repos" => [
          { "name" => "openproject", "upstream" => "opf/openproject", "base" => "dev" },
          { "name" => "foo",         "upstream" => "acme/foo",        "base" => "main" }
        ]
      ))
      registry = Registry.build(script_dir: script_dir, state_dir: state_dir)
      ctx = Struct.new(:state_dir, :script_dir, :log_file, :repos, :default_repo) do
        def op_host; "test.host"; end   # WP mirror namespace
      end.new(
        state_dir, script_dir, Pathname("/dev/null"), registry, registry.default
      )
      RepoHost.new(ctx)
    end

    def teardown_repo_host
      FileUtils.rm_rf(@repo_tmpdir) if @repo_tmpdir
    end

    def test_record_chosen_repos_parses_name_at_base_overrides
      host = repo_host
      st = host.state_for("42", "Fix the bug", "Bug")
      st.plan_file.write("REPOS: openproject@release/17.6, foo\n\n## Plan\nbody\n")

      host.record_chosen_repos(st)

      assert_equal ["openproject", "foo"], JSON.parse(st.target_repos_file.read)
      assert_equal({ "openproject" => "release/17.6" }, JSON.parse(st.target_base_file.read))
      refute_match(/REPOS:/, st.plan_file.read, "the REPOS line is stripped from the saved plan")

      op  = host.ctx.repos["openproject"]
      foo = host.ctx.repos["foo"]
      assert_equal "release/17.6", st.base_for(op), "override base wins for the chosen repo"
      assert_equal "main", st.base_for(foo), "a repo without an override uses its registry default"
    ensure
      teardown_repo_host
    end

    def test_no_target_base_file_when_no_base_requested
      host = repo_host
      st = host.state_for("43", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject\n## Plan\n")

      host.record_chosen_repos(st)

      refute st.target_base_file.exist?, "no override → no target_base.json"
      assert_equal "dev", st.base_for(host.ctx.repos["openproject"]), "falls back to the default base"
    ensure
      teardown_repo_host
    end

    def test_state_for_reloads_persisted_base_overrides
      host = repo_host
      st = host.state_for("44", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject@release/17.6\n## Plan\n")
      host.record_chosen_repos(st)

      reloaded = host.state_for("44", "Fix", "Bug")
      assert_equal({ "openproject" => "release/17.6" }, reloaded.bases)
      assert_equal "release/17.6", reloaded.base_for(host.ctx.repos["openproject"])
    ensure
      teardown_repo_host
    end

    def test_checkout_branch_fetches_and_branches_from_a_custom_base
      host = repo_host
      st = host.state_for("45", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject@release/17.6\n## Plan\n")
      host.record_chosen_repos(st)

      op = host.ctx.repos["openproject"]
      wt = FakeWorktree.new
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      host.checkout_branch(st, op)

      assert_equal [["origin", { ref: "release/17.6" }]], wt.fetched, "the custom base is fetched first"
      branch, opts = wt.checkouts.last
      assert_equal st.branch, branch
      assert_equal "origin/release/17.6", opts[:start_point], "the fix branch starts from the custom base"
    ensure
      teardown_repo_host
    end

    def test_checkout_branch_fetches_the_default_base_too
      # `./opilot` fetches each base once at launch, which an agent loop running
      # for days then outruns — so a fix branch cut without a fresh fetch would
      # start from however old that process is. This used to be skipped for the
      # default base on the grounds that provisioning had already covered it.
      host = repo_host
      st = host.state_for("46", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject\n## Plan\n")
      host.record_chosen_repos(st)

      op = host.ctx.repos["openproject"]
      wt = FakeWorktree.new
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      host.checkout_branch(st, op)

      assert_equal [["origin", { ref: "dev" }]], wt.fetched
      assert_equal "origin/dev", wt.checkouts.last[1][:start_point]
    ensure
      teardown_repo_host
    end

    # opf/openproject#24916 shipped an unrelated file: an earlier run left it
    # untracked in the clone and #stage_all's `git add --all` swept it into the
    # next work package's commit.
    def test_checkout_branch_clears_leftovers_before_cutting_a_new_branch
      host = repo_host
      st = host.state_for("47", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject\n## Plan\n")
      host.record_chosen_repos(st)

      op = host.ctx.repos["openproject"]
      wt = FakeWorktree.new(leftover: "app/models/stray.rb")
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      host.checkout_branch(st, op)

      assert_equal [["HEAD", { hard: true }]], wt.resets,
                   "resetting to origin/<base> would rewind a previous WP's branch"
      assert_includes wt.cleans, { force: true, d: true }, "untracked leftovers are removed"
      refute(wt.cleans.any? { |o| o[:x] || o[:X] }, "ignored files are the pd spec tree")
      assert_equal [[st.branch, { new_branch: true, start_point: "origin/dev" }]], wt.checkouts,
                   "nothing is checked out before the fix branch itself"
    ensure
      teardown_repo_host
    end

    # An existing branch may be a run resuming after it died between the LLM
    # writing files and the commit. That work is the branch's own.
    def test_checkout_branch_leaves_an_existing_branch_alone
      host = repo_host
      st = host.state_for("48", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject\n## Plan\n")
      host.record_chosen_repos(st)

      op = host.ctx.repos["openproject"]
      wt = FakeWorktree.new(branch_exists: true, leftover: "app/models/wip.rb")
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      host.checkout_branch(st, op)

      assert_empty wt.cleans, "a resumed branch keeps its uncommitted work"
      assert_empty wt.resets
      assert_equal [[st.branch, {}]], wt.checkouts
    ensure
      teardown_repo_host
    end

    # A clone that will not clean is worth a warning and a run, not a dead poll.
    def test_checkout_branch_survives_a_clone_it_cannot_clear
      host = repo_host
      st = host.state_for("49", "Fix", "Bug")
      st.plan_file.write("REPOS: openproject\n## Plan\n")
      host.record_chosen_repos(st)

      op = host.ctx.repos["openproject"]
      wt = FakeWorktree.new
      def wt.clean(**_opts) = raise(Git::FailedError.allocate)
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      host.checkout_branch(st, op)

      assert_equal st.branch, wt.checkouts.last[0], "the run continues"
      assert_equal [["branch.#{st.branch}.remote", "origin"],
                    ["branch.#{st.branch}.merge", "refs/heads/#{st.branch}"]], wt.configs
    ensure
      teardown_repo_host
    end

    # --- sync_base! (freshness of the tree the LLM reads) ---------------------

    def test_sync_base_fetches_and_moves_the_tree_onto_current_upstream
      # The bug this closes: nothing between runs moved the working tree, so a
      # plan or chat read the clone's original `git clone` commit — or, worse, a
      # leftover fix branch from an unrelated WP with its changes applied.
      host = repo_host
      wt = FakeWorktree.new
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      assert host.sync_base!(host.ctx.repos["openproject"])

      assert_equal [
        ["origin", { ref: "dev" }],
        ["origin", { ref: "+refs/heads/release/*:refs/remotes/origin/release/*", tags: true }]
      ], wt.fetched, "the base, then the refs a release question reads"
      assert_equal [["origin/dev", {}]], wt.checkouts,
                   "detached at the fetched ref, not a local base branch"
    ensure
      teardown_repo_host
    end

    def test_sync_base_leaves_a_dirty_tree_strictly_alone
      # Uncommitted work exists nowhere else — a checkout would destroy it.
      host = repo_host
      wt = FakeWorktree.new(dirty: true)
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      refute host.sync_base!(host.ctx.repos["openproject"])

      assert_empty wt.checkouts
      assert_empty wt.fetched, "a dirty tree short-circuits before the fetch too"
    ensure
      teardown_repo_host
    end

    def test_sync_base_survives_an_unreachable_origin
      # Answering from a stale tree beats refusing to answer, so this warns
      # rather than taking the run down.
      host = repo_host
      wt = FakeWorktree.new(fetch_error: StandardError.new("network is unreachable"))
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      refute host.sync_base!(host.ctx.repos["openproject"])

      assert_empty wt.checkouts
    ensure
      teardown_repo_host
    end

    def test_sync_base_survives_a_failed_tag_fetch
      # Best-effort, unlike the base fetch: a repo with no release/* namespace is
      # normal, and the tree still has to move onto current upstream. Only the
      # release and tag answers go stale.
      host = repo_host
      wt = FakeWorktree.new(read_refs_error: StandardError.new("couldn't find remote ref"))
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })

      assert host.sync_base!(host.ctx.repos["openproject"])

      assert_equal [["origin", { ref: "dev" }]], wt.fetched, "the base fetch still landed"
      assert_equal [["origin/dev", {}]], wt.checkouts, "and the tree still moved"
    ensure
      teardown_repo_host
    end

    def test_sync_bases_for_reading_covers_every_repo_it_is_given
      host = repo_host
      seen = {}
      host.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = seen[k] = FakeWorktree.new })

      host.sync_bases_for_reading(host.ctx.repos.all)

      assert_equal %w[foo openproject], seen.keys.sort
      assert_equal ["origin", { ref: "main" }], seen["foo"].fetched.first,
                   "each repo is synced to its own base, not the default one"
    ensure
      teardown_repo_host
    end

  # --- demote_headings (OpenProject comments) ------------------------------

  def test_demote_headings_turns_every_atx_level_into_bold
    (1..6).each do |level|
      assert_equal "**Title**\n", Helpers.demote_headings("#{"#" * level} Title\n")
    end
    assert_equal "**Title**", Helpers.demote_headings("### Title"), "no trailing newline is fine"
    assert_equal "**Title**\n", Helpers.demote_headings("### Title ###\n"), "closing run is dropped"
    assert_equal "**Title**\n", Helpers.demote_headings("  ### Title\n"),
                 "up to 3 leading spaces is still a heading; the indent carried nothing"
    assert_equal "\n", Helpers.demote_headings("###\n"), "an empty heading leaves an empty line"
  end

  def test_demote_headings_leaves_everything_that_is_not_a_heading
    [
      "#59942 is the ticket\n",         # no space after # — not a heading
      "a # b\n",                        # mid-line hash
      "    # indented four is code\n",  # 4 spaces = code block, not a heading
      "**Already bold**\n"
    ].each { |text| assert_equal text, Helpers.demote_headings(text) }
  end

  def test_demote_headings_skips_fenced_code_blocks
    # A leading # in a fence is a comment or a shell prompt, not a heading.
    text = "Steps:\n\n```bash\n# install\nbundle install\n```\n\n## After\n"
    out  = Helpers.demote_headings(text)

    assert_includes out, "# install", "the code comment survives verbatim"
    assert_includes out, "**After**", "a heading after the fence is still demoted"
  end

  def test_demote_headings_handles_a_whole_plan
    plan = <<~MD
      # Fix the thing

      Some context.

      ## Files

      - app/models/foo.rb
    MD
    out = Helpers.demote_headings(plan)

    refute_match(/^#+ /, out, "no heading markup survives")
    assert_includes out, "**Fix the thing**"
    assert_includes out, "**Files**"
    assert_includes out, "- app/models/foo.rb", "list items are untouched"
  end
  end
end
