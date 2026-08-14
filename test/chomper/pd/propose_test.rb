require_relative "../../test_helper"
require "tmpdir"

module Chomper
  module PD
    # `pd propose` — the stage that turns intake into a validated OpenSpec change
    # proposal. The pieces exercised here are the ones that gate the run: the
    # validator re-prompt loop, the write scope, and work-package idempotency.
    class ProposeTest < Minitest::Test
      # Plays back one scripted verdict per validate call.
      class FakeOpenSpec
        attr_reader :calls

        def initialize(*verdicts)
          @verdicts = verdicts
          @calls = 0
        end

        def validate(_change_id = nil, strict: true)
          @calls += 1
          ok = @verdicts.shift
          OpenSpec::Result.new(ok: ok, out: ok ? '{"items":[]}' : failure_json, err: "")
        end

        # The real wrapper hands the CLI's own artifact instructions to the prompt.
        def instructions_for_all(_change_id, &_rewrite)
          "<artifact id=\"proposal\">write proposal.md</artifact>"
        end

        def failure_json
          JSON.generate("items" => [{ "name" => "add-x", "passed" => false,
                                      "issues" => [{ "message" => "requirement has no scenarios" }] }])
        end
      end

      # Writes whatever it was told to on each call, and records the prompts.
      class FakeHarness
        attr_reader :prompts

        def initialize(&on_run)
          @prompts = []
          @on_run = on_run
        end

        def run(prompt, tools: nil, model: nil, session_file: nil)
          @prompts << prompt
          @on_run ? @on_run.call(@prompts.length) : ""
        end
      end

      class FakeOP
        attr_reader :created, :comments

        def initialize(create_code: 201, create_id: 59_942)
          @create_code = create_code
          @create_id = create_id
          @created = []
          @comments = []
        end

        def create_work_package(payload, notify: false)
          @created << payload
          @create_code == 201 ? [201, { "id" => @create_id }] : [@create_code, nil]
        end

        def post_activity(wp_id, comment:, internal: true)
          @comments << [wp_id, comment]
          [201, {}]
        end
      end

      def setup
        @tmpdir = Pathname(Dir.mktmpdir)
        @ctx    = Context.build(@tmpdir)
        @repo   = @ctx.default_repo
        @repo.worktree_host.mkpath
        Git.init(@repo.worktree_host.to_s)
        @git = Git.open(@repo.worktree_host.to_s)
        @git.config("user.name", "test")
        @git.config("user.email", "test@localhost")
        (@repo.worktree_host / "app.rb").write("puts 1\n")
        @git.add(all: true)
        @git.commit("initial")

        @store = ChangeStore.new(@ctx, @repo)
        (@store.tree / "changes").mkpath
        (@store.tree / "config.yaml").write("schema: spec-driven\n")
        @state = ChangeState.new(change_id: "add-x", store: @store, state_dir: (@tmpdir / "s").tap(&:mkpath))
        seed_intake!
        @store.materialise!
      end

      def teardown
        FileUtils.rm_rf(@tmpdir)
      end

      def seed_intake!
        dir = @store.change_dir("add-x") / "intake"
        dir.mkpath
        (dir / "001-concept.md").write("---\nid: 118\n---\n# Concept\nBody\n")
      end

      # Write a plausible proposal into the WORKING tree, as the LLM would.
      def write_proposal!
        dir = @state.working_change_dir
        dir.mkpath
        (dir / "proposal.md").write("# Recurring meetings\nWhy this exists.\n")
        (dir / "tasks.md").write("## RRule parsing\n- [ ] parse\n\n## Materialisation\n- [ ] expand\n")
      end

      def runner(harness: nil, openspec: nil, op: nil)
        Runner.new(@ctx, op: op || FakeOP.new, intake: Object.new,
                          harness: harness || FakeHarness.new, openspec: openspec,
                          publish: Object.new)
      end

      # --- the validator loop ----------------------------------------------

      def test_a_valid_proposal_needs_no_revision
        harness = FakeHarness.new
        spec   = FakeOpenSpec.new(true)
        runner(harness: harness, openspec: spec).send(:validate_proposal!, @state, @repo)

        assert_equal 1, spec.calls
        assert_empty harness.prompts, "a proposal that validates must not be re-prompted"
      end

      def test_a_failing_proposal_is_re_prompted_with_the_validator_output
        harness = FakeHarness.new
        spec   = FakeOpenSpec.new(false, true)
        runner(harness: harness, openspec: spec).send(:validate_proposal!, @state, @repo)

        assert_equal 2, spec.calls
        assert_equal 1, harness.prompts.length
        assert_includes harness.prompts.first, "requirement has no scenarios",
                        "the re-prompt must carry what the validator actually said"
        assert_includes harness.prompts.first, "openspec/changes/add-x"
      end

      def test_the_loop_gives_up_after_the_attempt_cap
        harness = FakeHarness.new
        spec   = FakeOpenSpec.new(false, false, false)
        error = assert_raises(Chomper::FatalError) do
          runner(harness: harness, openspec: spec).send(:validate_proposal!, @state, @repo)
        end

        assert_match(/still fails `openspec validate --strict`/, error.message)
        assert_equal Runner::MAX_VALIDATE_ATTEMPTS, harness.prompts.length
        assert_equal Runner::MAX_VALIDATE_ATTEMPTS + 1, spec.calls
      end

      # --- the scope refusal ------------------------------------------------

      def test_a_written_proposal_beats_prose_mentioning_the_sentinel
        # Regression: the LLM narrates its reasoning ("this is one feature, so I
        # wrote a proposal rather than TOO_BROAD"), and searching the whole output
        # for the sentinel read that explanation as the verdict — discarding four
        # files it had just written.
        harness = FakeHarness.new { write_proposal!; "I judged the scope fine, so I wrote a proposal rather than TOO_BROAD." }
        spec   = FakeOpenSpec.new(true)

        assert_nil runner(harness: harness, openspec: spec).send(:write_proposal, @state, @repo)
        assert (@state.working_change_dir / "proposal.md").exist?, "the proposal must survive"
        assert_equal 1, spec.calls, "and must still be validated"
      end

      def test_the_prompt_carries_openspecs_own_artifact_instructions
        # Not a paraphrase: the format comes from the CLI we pin, so it tracks the
        # tool rather than chomper's memory of a design doc. `validate --strict`
        # checks delta structure but not, say, the proposal's Capabilities section,
        # so a hand-written format drifts without anything noticing.
        harness = FakeHarness.new { write_proposal!; "done" }
        runner(harness: harness, openspec: FakeOpenSpec.new(true)).send(:write_proposal, @state, @repo)

        prompt = harness.prompts.first
        assert_includes prompt, "write proposal.md", "the CLI's instructions must reach the prompt"
        assert_includes prompt, "come from the `openspec` CLI itself"
        refute_includes prompt, "ADDED / MODIFIED / REMOVED",
                        "the hand-written format block should be gone"
      end

      def test_the_sentinel_counts_only_when_it_leads_the_answer
        run = runner
        assert run.send(:too_broad?, "TOO_BROAD\n### Suggested split\n- a\n- b\n")
        assert run.send(:too_broad?, "I can't do this.\nTOO_BROAD\n- a\n"), "a short preamble is tolerated"
        refute run.send(:too_broad?, "...long explanation...\n" * 8 + "rather than TOO_BROAD.\n")
        refute run.send(:too_broad?, "This is not too broad, so here is the proposal.")
        refute run.send(:too_broad?, "")
      end

      def test_a_genuine_refusal_writes_nothing_and_reports_the_split
        harness = FakeHarness.new { "TOO_BROAD\n### Suggested split\n- reading mode\n- export to PDF\n" }
        out, = capture_io do
          assert_equal :too_broad, runner(harness: harness).send(:write_proposal, @state, @repo)
        end
        assert_match(/more than one atomic feature/, out)
        assert_match(/reading mode/, out)
      end

      def test_a_run_that_writes_nothing_and_says_nothing_is_an_error
        error = assert_raises(Chomper::FatalError) do
          runner(harness: FakeHarness.new { "I had a look around." }).send(:write_proposal, @state, @repo)
        end
        assert_match(/no proposal was written/, error.message)
      end

      # --- the write scope --------------------------------------------------

      def test_a_run_confined_to_its_change_directory_passes
        write_proposal!
        runner.send(:enforce_write_scope!, @state) # must not raise
      end

      def test_touching_source_discards_the_run
        # A planning stage must not be able to modify source. pi-guards.ts only
        # confines the LLM to /repos; this is the path-level half.
        write_proposal!
        (@repo.worktree_host / "app.rb").write("puts 666\n")

        error = assert_raises(Chomper::FatalError) { runner.send(:enforce_write_scope!, @state) }
        assert_match(/wrote outside openspec\/changes\/add-x/, error.message)
        assert_includes error.message, "app.rb"
        assert_equal "puts 1\n", (@repo.worktree_host / "app.rb").read, "the clone must be reset"
      end

      def test_a_revision_of_already_committed_spec_files_is_not_treated_as_a_stray
        # Regression: propose force-adds the change dir when it commits, so from
        # the second run on the change's OWN files are tracked. The git side of the
        # scope check wasn't filtered by scope, so every revision came back as
        # out-of-scope, got reset, and gh-agent posted "sorry — I hit an error"
        # instead of the revision. This broke the whole PR-iteration loop.
        write_proposal!
        @git.add("openspec/changes/add-x", force: true)
        @git.commit("[add-x] Propose add-x")

        (@state.working_change_dir / "proposal.md").write("# Recurring meetings\nRevised.\n")
        runner.send(:enforce_write_scope!, @state) # must not raise

        assert_equal "# Recurring meetings\nRevised.\n", (@state.working_change_dir / "proposal.md").read,
                     "the revision must survive the scope check"
      end

      def test_source_edits_are_still_caught_once_the_spec_files_are_tracked
        # The narrower filter must not blind the check to what it exists for.
        write_proposal!
        @git.add("openspec/changes/add-x", force: true)
        @git.commit("[add-x] Propose add-x")
        (@repo.worktree_host / "app.rb").write("puts 666\n")

        error = assert_raises(Chomper::FatalError) { runner.send(:enforce_write_scope!, @state) }
        assert_includes error.message, "app.rb"
      end

      def test_writing_into_another_change_discards_the_run
        # Inside openspec/ git sees nothing (the tree is excluded), so this is
        # caught by diffing the working tree against the canonical store.
        write_proposal!
        other = @store.working_tree / "changes" / "someone-elses-change"
        other.mkpath
        (other / "proposal.md").write("not mine\n")

        error = assert_raises(Chomper::FatalError) { runner.send(:enforce_write_scope!, @state) }
        assert_match(/changes\/someone-elses-change/, error.message)
      end

      def test_editing_the_shared_specs_tree_discards_the_run
        write_proposal!
        specs = @store.working_tree / "specs" / "meetings"
        specs.mkpath
        (specs / "spec.md").write("rewritten\n")

        error = assert_raises(Chomper::FatalError) { runner.send(:enforce_write_scope!, @state) }
        assert_match(%r{specs/meetings/spec\.md}, error.message)
      end

      # --- preconditions ----------------------------------------------------

      def test_propose_refuses_without_intake
        FileUtils.rm_rf((@store.change_dir("add-x") / "intake").to_s)
        error = assert_raises(Chomper::FatalError) { runner.send(:require_intake!, @state, "add-x") }
        assert_match(/has no intake yet/, error.message)
      end

      def test_propose_refuses_without_a_store
        FileUtils.rm_rf((@store.tree / "config.yaml").to_s)
        error = assert_raises(Chomper::FatalError) { runner.send(:require_intake!, @state, "add-x") }
        assert_match(/pd init/, error.message)
      end

      # --- the work package -------------------------------------------------

      def test_the_feature_work_package_is_created_once_and_reused
        # It accumulates comments and history that exist nowhere else, so a second
        # propose run must link the existing one rather than mint a duplicate.
        @state.merge_tracker("project_id" => "42")
        ResolvedIds.new(@ctx, op: Object.new).path.tap do |p|
          p.dirname.mkpath
          p.write(JSON.generate("project_id" => "42", "types" => { "parent" => { "id" => 7 } }))
        end
        write_proposal!
        op = FakeOP.new
        run = runner(op: op)

        first = run.send(:ensure_feature_wp, @state, "https://github.com/bot/openproject/pull/14")
        assert_equal 59_942, first
        assert_equal 59_942, @state.parent_wp
        assert_equal 1, op.created.length
        assert_equal "/api/v3/types/7", op.created.first.dig("_links", "type", "href")
        assert_equal "Recurring meetings", op.created.first["subject"], "subject comes from the proposal heading"

        second = run.send(:ensure_feature_wp, @state, "https://github.com/bot/openproject/pull/14")
        assert_equal 59_942, second
        assert_equal 1, op.created.length, "a second run must not create a second work package"
        assert_equal 2, op.comments.length, "but it does re-post the PR link"
      end

      def test_work_package_creation_is_skipped_without_resolved_ids
        write_proposal!
        op = FakeOP.new
        assert_nil capture_io { runner(op: op).send(:ensure_feature_wp, @state, "url") }.then { @state.parent_wp }
        assert_empty op.created
      end

      class FakePublish
        def login = "op-chomper"
        def open_spec_pr(_state, _repo, body:) = "https://github.com/bot/openproject/pull/14"
      end

      def test_proposing_writes_nothing_to_openproject
        # The spec PR is the approval gate, so a FEATURE created here would
        # announce a planned feature before anyone agreed to it — and work
        # packages are never deleted, so every abandoned proposal would leave a
        # permanent empty one behind. `generate-wp` creates it, with its children.
        write_proposal!
        op  = FakeOP.new
        run = runner(op: op)
        run.instance_variable_set(:@publish, FakePublish.new)

        out, = capture_io { run.send(:publish_proposal, @state, @repo) }

        assert_empty op.created, "propose must not create a work package"
        assert_empty op.comments
        assert_nil @state.parent_wp
        assert_match(/Proposal PR/, out)
        assert_match(/pd generate-wp/, out, "it should point at the stage that does create one")
      end

      # --- the PR body ------------------------------------------------------

      def test_the_pr_body_states_what_the_change_will_generate
        write_proposal!
        @state.merge_tracker(
          "intake" => { "documents" => [{ "id" => 118, "title" => "Concept", "updated_at" => "2026-07-28" }] },
          "unconvertible" => [{ "file" => "old.doc", "reason" => "legacy binary" }]
        )
        body = runner.send(:proposal_pr_body, @state)

        assert_includes body, "**Work packages this will generate:** 2"
        assert_includes body, "- RRule parsing (1 item)"
        assert_includes body, "old.doc", "an unreadable attachment must be visible to the reviewer"
        assert_includes body, "Merging is optional"

        # A bare "#118" would autolink to issue/PR 118 in whatever repo the PR
        # lives in, pointing the reviewer at something unrelated.
        assert_includes body, "[#118 Concept](#{@ctx.op_url}/documents/118)"
        refute_match(/^- #118/, body)
      end
    end
  end
end
