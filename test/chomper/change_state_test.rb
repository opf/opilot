require_relative "../test_helper"
require "tmpdir"

module Chomper
  class ChangeStateTest < Minitest::Test
    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = Context.build(@tmpdir)
      @repo   = @ctx.default_repo
      # A bare clone stand-in: the store only needs the worktree dir and its
      # .git/info directory to install the exclude entry.
      (@repo.worktree_host / ".git" / "info").mkpath
      @store  = ChangeStore.new(@ctx, @repo)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    # Seed the store without shelling out to the openspec CLI, which is not on
    # PATH outside the runner image.
    def seed_store!(change_id = "add-recurring-meetings", tasks: "## RRule parsing (#59943)\n")
      (@store.tree / "config.yaml").dirname.mkpath
      (@store.tree / "config.yaml").write("schema: spec-driven\n")
      dir = @store.change_dir(change_id)
      dir.mkpath
      (dir / "tasks.md").write(tasks)
      change_id
    end

    def test_store_root_is_namespaced_by_repo_and_holds_an_openspec_tree
      assert_equal @ctx.state_dir / "openspec" / @repo.name, @store.root
      assert_equal @store.root / "openspec", @store.tree,
                   "the tree sits under the root so openspec resolves it like a real repo"
    end

    def test_exclude_keeps_the_working_tree_out_of_unrelated_commits
      # Helpers#commit does `add(all: true)`; without this entry the whole spec
      # tree would be swept into an unrelated bug-fix commit.
      @store.exclude_from_clone!
      exclude = @repo.worktree_host / ".git" / "info" / "exclude"
      assert_includes exclude.read.lines.map(&:strip), "openspec/"
    end

    def test_exclude_is_idempotent_and_preserves_existing_entries
      exclude = @repo.worktree_host / ".git" / "info" / "exclude"
      exclude.write("*.swp\n")
      3.times { @store.exclude_from_clone! }
      entries = exclude.read.lines.map(&:strip).reject(&:empty?)
      assert_equal ["*.swp", "openspec/"], entries
    end

    # The highest-consequence guard in this design: Helpers#commit does
    # `add(all: true)`, so without the exclude an entire spec tree would be
    # swept into an unrelated bug-fix commit and pushed to a PR. Exercised
    # against real git rather than by asserting on the exclude file's contents.
    def test_a_present_spec_tree_is_not_swept_into_an_unrelated_commit
      clone = @repo.worktree_host
      Git.init(clone.to_s)
      git = Git.open(clone.to_s)
      git.config("user.name", "test")
      git.config("user.email", "test@localhost")

      (clone / "app.rb").write("puts 1\n")
      git.add(all: true)
      git.commit("initial")

      seed_store!
      @store.materialise!
      assert (clone / "openspec" / "changes" / "add-recurring-meetings" / "tasks.md").exist?
      (clone / "app.rb").write("puts 2\n")

      git.add(all: true)
      staged = git.status.changed.keys + git.status.added.keys
      assert_includes staged, "app.rb"
      refute staged.any? { |p| p.start_with?("openspec/") },
             "the spec tree must never reach an unrelated commit (staged: #{staged.inspect})"
    end

    def test_the_propose_flow_can_still_commit_the_tree_deliberately
      # The exclude must not lock the tree out entirely: propose commits it with
      # `git add -f` on the spec branch.
      clone = @repo.worktree_host
      Git.init(clone.to_s)
      git = Git.open(clone.to_s)
      git.config("user.name", "test")
      git.config("user.email", "test@localhost")
      (clone / "app.rb").write("puts 1\n")
      git.add(all: true)
      git.commit("initial")

      seed_store!
      @store.materialise!
      git.add("openspec/changes/add-recurring-meetings", force: true)
      assert git.status.added.keys.any? { |p| p.start_with?("openspec/") },
             "an explicit force-add is how the spec PR gets its content"
    end

    def test_materialise_copies_canonical_into_the_clone
      seed_store!
      @store.materialise!
      assert (@store.working_tree / "changes" / "add-recurring-meetings" / "tasks.md").exist?
    end

    def test_materialise_mirrors_rather_than_merges
      # An archive run MOVES a change directory; a merge would resurrect it.
      seed_store!("live-change")
      @store.materialise!
      stale = @store.working_tree / "changes" / "archived-change"
      stale.mkpath
      (stale / "tasks.md").write("## Gone\n")

      @store.materialise!
      refute stale.exist?, "a change absent from the store must not survive in the clone"
      assert (@store.working_tree / "changes" / "live-change").exist?
    end

    def test_persist_copies_the_clone_back_and_commits
      seed_store!
      @store.materialise!
      (@store.working_tree / "changes" / "add-recurring-meetings" / "proposal.md").write("# Proposal\n")

      @store.persist!("Propose add-recurring-meetings")
      assert (@store.change_dir("add-recurring-meetings") / "proposal.md").exist?
      refute_nil @store.head_sha, "the store is versioned, so a bad run is recoverable"
    end

    def test_change_ids_excludes_the_archive_directory
      seed_store!("one")
      seed_store!("two")
      (@store.changes_dir / "archive" / "2026-08-02-old").mkpath
      assert_equal %w[one two], @store.change_ids
    end

    def test_reverse_index_maps_work_packages_back_to_their_change
      # `pd implement <wp-id>` has only the id; the repo is what says which
      # change it belongs to (the design's invariant 3).
      seed_store!("add-recurring-meetings",
                  tasks: "## RRule parsing (#59943)\n- [ ] a\n\n## Materialisation (#59944)\n")
      seed_store!("other-change", tasks: "## Something (#60001)\n")

      index = @store.reverse_index
      assert_equal "add-recurring-meetings", index["59943"][:change_id]
      assert_equal "RRule parsing", index["59943"][:section]
      assert_equal "add-recurring-meetings", index["59944"][:change_id]
      assert_equal "other-change", index["60001"][:change_id]
      assert_equal "add-recurring-meetings", @store.change_id_for_wp(59_943)
    end

    def test_reverse_index_ignores_unbound_sections
      seed_store!("c", tasks: "## Bound (#1)\n\n## Unbound\n")
      assert_equal %w[1], @store.reverse_index.keys
    end

    def test_setup_is_skipped_when_already_initialised
      seed_store!
      refute_nil @store.tree / "config.yaml"
      assert @store.initialized?
    end

    def test_change_state_paths_and_tracker_round_trip
      change_id = seed_store!
      state = ChangeState.new(change_id: change_id, store: @store, state_dir: @tmpdir / "s")
      assert_equal @repo.name, state.repo.name, "the repo comes from the store, not a second member"
      assert_equal @tmpdir / "s" / "session_id", state.session_file
      assert_equal @tmpdir / "s" / "pr_url.txt", state.pr_url_file
      assert_equal "spec/add-recurring-meetings", state.branch
      assert_equal "archive/add-recurring-meetings", state.archive_branch
      assert_equal @store.change_dir(change_id) / "tracker.json", state.tracker_file
      assert_equal "/repos/openproject/openspec/changes/add-recurring-meetings",
                   state.working_change_container

      state.write_tracker("parent_wp" => 59_942)
      assert_equal 59_942, state.parent_wp
      state.merge_tracker("repo" => "openproject")
      assert_equal 59_942, state.tracker["parent_wp"], "merge preserves existing keys"
      assert_equal "openproject", state.tracker["repo"]
    end
  end
end
