require_relative "../test_helper"
require "tmpdir"

module Chomper
  # `pd generate-wp` — the stage that turns a reviewed proposal into work
  # packages. Everything worth testing here is about not writing twice: a work
  # package cannot be deleted, so every path has to be re-runnable.
  class ProductGenerateWpTest < Minitest::Test
    # Hands out increasing ids, and can be told which POST to fail.
    class FakeOP
      attr_reader :created, :comments

      def initialize(fail_at: nil, first_id: 500)
        @fail_at  = fail_at
        @next_id  = first_id
        @created  = []
        @comments = []
      end

      def create_work_package(payload, notify: false)
        @created << payload
        return [422, nil] if @fail_at == @created.length
        id = @next_id
        @next_id += 1
        [201, { "id" => id }]
      end

      def post_activity(wp_id, comment:, internal: true)
        @comments << [wp_id, comment]
        [201, {}]
      end
    end

    TASKS = <<~MD
      ## RRule parsing
      - [ ] parse the rule
      - [ ] reject junk

      ## Materialisation
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
      # The same state_dir the runner derives, so pr_url.txt is the one it reads.
      @state = ChangeState.new(change_id: "add-x", store: @store,
                               state_dir: Helpers.change_dir(@ctx, "add-x").tap(&:mkpath))

      dir = @store.change_dir("add-x")
      (dir / "intake").mkpath
      (dir / "intake" / "001-concept.md").write("---\nid: 118\n---\n# Concept\n")
      (dir / "proposal.md").write("# Recurring meetings\nWhy this exists.\n")
      (dir / "tasks.md").write(TASKS)
      @state.merge_tracker("project_id" => "42")
      @state.pr_url_file.write("https://github.com/bot/openproject/pull/14")
      seed_resolved_ids!
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def seed_resolved_ids!(parent: { "id" => 7, "name" => "FEATURE" },
                          child: { "id" => 9, "name" => "IMPLEMENTATION" })
      path = ResolvedIds.new(@ctx, op: Object.new).path
      path.dirname.mkpath
      path.write(JSON.generate("project_id" => "42",
                               "types" => { "parent" => parent, "child" => child }.compact))
    end

    def runner(op)
      ProductRunner.new(@ctx, op: op, intake: Object.new, claude: Object.new, publish: Object.new)
    end

    def generate(op, *args)
      result = nil
      out, = capture_io { result = runner(op).run(["generate-wp", "add-x", *args]) }
      [result, out]
    end

    def store_tasks
      (@store.change_dir("add-x") / "tasks.md").read
    end

    # --- the happy path ---------------------------------------------------

    def test_it_creates_the_feature_and_one_child_per_section
      op = FakeOP.new
      result, = generate(op)

      assert_equal 500, result[:parent]
      assert_equal ["RRule parsing", "Materialisation"], result[:created].map { |c| c["title"] }
      assert_empty result[:failed]

      feature, first, second = op.created
      assert_equal "Recurring meetings", feature["subject"], "the FEATURE is titled from the proposal"
      assert_equal "/api/v3/types/7", feature.dig("_links", "type", "href")
      assert_nil feature.dig("_links", "parent")

      assert_equal "RRule parsing", first["subject"]
      assert_equal "/api/v3/types/9", second.dig("_links", "type", "href"), "children get the child type"
      assert_equal "/api/v3/projects/42", second.dig("_links", "project", "href")
      assert_equal "/api/v3/work_packages/500", second.dig("_links", "parent", "href"),
                   "children hang off the FEATURE"
    end

    def test_the_child_description_carries_the_checklist_and_the_proposal_link
      op = FakeOP.new
      generate(op)

      raw = op.created[1].dig("description", "raw")
      assert_includes raw, "- [ ] parse the rule"
      assert_includes raw, "- [ ] reject junk"
      assert_includes raw, "https://github.com/bot/openproject/pull/14"
      refute_includes raw, "expand occurrences", "each section gets only its own items"
    end

    def test_the_ids_are_bound_back_into_tasks_md_and_persisted
      # The binding is the only link from a spec section to its work package, and
      # `pd implement <wp-id>` resolves the change through it — so it has to land
      # in the canonical store, not just the disposable working copy.
      generate(FakeOP.new)

      assert_includes store_tasks, "## RRule parsing (#501)"
      assert_includes store_tasks, "## Materialisation (#502)"
      assert_equal({ change_id: "add-x", section: "RRule parsing" },
                   @store.reverse_index["501"])
      assert_equal({ change_id: "add-x", section: "Materialisation" },
                   @store.reverse_index["502"])
      assert_equal TASKS.lines.length, store_tasks.lines.length, "only the headings change"
    end

    def test_the_parent_is_recorded_and_the_pr_link_commented
      op = FakeOP.new
      generate(op)

      assert_equal 500, @state.parent_wp
      assert_equal [500], op.comments.map(&:first), "only the FEATURE gets the proposal link"
      assert_match(/up for review.*pull\/14/, op.comments.first.last)
    end

    # --- re-runs ----------------------------------------------------------

    def test_a_second_run_creates_nothing
      first_op = FakeOP.new
      generate(first_op)
      assert_equal 3, first_op.created.length

      second_op = FakeOP.new(first_id: 900)
      result, out = generate(second_op)

      assert_empty second_op.created, "neither the FEATURE nor a single child may be created twice"
      assert_equal 500, result[:parent]
      assert_empty result[:created]
      assert_includes store_tasks, "## RRule parsing (#501)", "the existing bindings survive"
      assert_match(%r{2/2 section\(s\) bound}, out)
    end

    def test_a_section_added_after_the_first_run_is_the_only_one_generated
      generate(FakeOP.new)
      tasks = @store.change_dir("add-x") / "tasks.md"
      tasks.write("#{tasks.read}\n## Timezone handling\n- [ ] DST\n")
      @store.materialise!(preserve: false)

      op = FakeOP.new(first_id: 700)
      result, = generate(op)

      assert_equal ["Timezone handling"], result[:created].map { |c| c["title"] }
      assert_equal 1, op.created.length
      assert_includes store_tasks, "## Timezone handling (#700)"
      assert_includes store_tasks, "## RRule parsing (#501)"
    end

    # --- partial failure --------------------------------------------------

    def test_a_failed_child_leaves_the_others_bound_and_is_re_runnable
      op = FakeOP.new(fail_at: 2) # the FEATURE, then the first child fails
      result, out = generate(op)

      assert_equal ["RRule parsing"], result[:failed]
      assert_equal ["Materialisation"], result[:created].map { |c| c["title"] }
      assert_includes store_tasks, "## RRule parsing\n", "the failed section stays unbound"
      assert_includes store_tasks, "## Materialisation (#501)"
      assert_match(/could not be created/, out)

      retry_op = FakeOP.new(first_id: 800)
      generate(retry_op)
      assert_equal 1, retry_op.created.length, "only the section that failed is retried"
      assert_includes store_tasks, "## RRule parsing (#800)"
    end

    # --- preconditions ----------------------------------------------------

    def test_it_refuses_without_a_proposal
      (@store.change_dir("add-x") / "tasks.md").delete
      error = assert_raises(Chomper::FatalError) { generate(FakeOP.new) }
      assert_match(/no tasks\.md yet/, error.message)
      assert_match(/pd propose add-x/, error.message)
    end

    def test_it_refuses_when_tasks_md_has_no_sections
      (@store.change_dir("add-x") / "tasks.md").write("Some prose, no headings.\n")
      error = assert_raises(Chomper::FatalError) { generate(FakeOP.new) }
      assert_match(/no top-level/, error.message)
    end

    def test_it_refuses_without_resolved_ids
      # Half a tree is worse than none when the halves can't be deleted, so the
      # check happens before the first POST.
      seed_resolved_ids!(child: nil)
      op = FakeOP.new
      error = assert_raises(Chomper::FatalError) { generate(op) }
      assert_match(/pd init/, error.message)
      assert_match(/IMPLEMENTATION type id/, error.message)
      assert_empty op.created, "nothing may be created once the ids are known to be incomplete"
    end

    def test_duplicate_section_titles_are_refused_before_anything_is_created
      # bind_id matches on heading text, so two identical unbound titles would
      # both take the first id — one work package for two chunks of work.
      (@store.change_dir("add-x") / "tasks.md")
        .write("## Parsing\n- [ ] a\n\n## Parsing\n- [ ] b\n")
      op = FakeOP.new
      error = assert_raises(Chomper::FatalError) { generate(op) }

      assert_match(/more than one top-level section titled/, error.message)
      assert_includes error.message, "Parsing"
      assert_empty op.created
    end

    def test_a_missing_spec_pr_does_not_block_the_run
      @state.pr_url_file.delete
      op = FakeOP.new
      result, = generate(op)

      assert_equal 2, result[:created].length
      assert_empty op.comments, "there is no PR to link, so no comment is posted"
      refute_includes op.created[1].dig("description", "raw"), "proposal]("
    end
  end
end
