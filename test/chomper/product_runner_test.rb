require_relative "../test_helper"
require "tmpdir"

module Chomper
  class ProductRunnerTest < Minitest::Test
    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = Context.build(@tmpdir)
      @repo   = @ctx.default_repo
      (@repo.worktree_host / ".git" / "info").mkpath
      @runner = ProductRunner.new(@ctx, op: Object.new, intake: Object.new)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def options(*args)
      @runner.send(:parse_options, args)
    end

    def test_parses_repeatable_doc_ids_in_both_forms
      opts = options("42", "add-x", "--doc-id", "118", "--doc-id=119")
      assert_equal %w[42 add-x], opts[:positional]
      assert_equal %w[118 119], opts[:doc_ids]
    end

    def test_parses_repo_in_both_forms
      assert_equal "ck", options("--repo", "ck")[:repo]
      assert_equal "ck", options("--repo=ck")[:repo]
    end

    def test_rejects_unknown_options_and_missing_values
      assert_raises(Chomper::FatalError) { options("--nope") }
      assert_raises(Chomper::FatalError) { options("--doc-id") }
      assert_raises(Chomper::FatalError) { options("--doc-id", "--repo") }
    end

    def test_change_ids_are_validated_not_sanitised
      # The change id becomes a directory name everything downstream binds to;
      # silently rewriting it would break the binding the operator thinks they
      # made, so a bad one is refused instead.
      %w[add-recurring-meetings a 9lives x-1-y].each do |good|
        @runner.send(:validate_change_id!, good)
      end
      ["Add-Thing", "add thing", "-leading", "add_thing", "../escape", ""].each do |bad|
        assert_raises(Chomper::FatalError, "#{bad.inspect} should be refused") do
          @runner.send(:validate_change_id!, bad)
        end
      end
    end

    # The unit check above only proves the predicate; this proves the command
    # actually runs it — and runs it before anything touches disk or the network,
    # so a malformed id can never become a directory name.
    def test_intake_refuses_a_malformed_change_id_before_doing_any_work
      seeded_store
      # (a leading dash never gets this far — parse_options rejects it as a flag)
      ["Read Only", "Read-Only", "read_only", "../escape", "read.only"].each do |bad|
        error = assert_raises(Chomper::FatalError, "#{bad.inspect} should be refused") do
          ProductRunner.new(@ctx, op: Object.new, intake: FakeIntake.new).run(["intake", "42", bad])
        end
        assert_match(/invalid change id/, error.message)
      end
      refute (@ctx.state_dir / "openspec" / @repo.name / "openspec" / "changes").exist?,
             "a refused id must not have created anything"
    end

    def test_unknown_repo_names_are_reported_with_the_available_set
      error = assert_raises(Chomper::FatalError) { @runner.send(:resolve_repo, "nope") }
      assert_match(/unknown repo "nope"/, error.message)
      assert_match(/openproject/, error.message)
    end

    def test_repo_defaults_to_the_registry_default
      assert_equal @ctx.default_repo.name, @runner.send(:resolve_repo, nil).name
    end

    def test_intake_refuses_before_the_store_is_seeded
      error = assert_raises(Chomper::FatalError) { @runner.intake("42", "add-x") }
      assert_match(/run `\.\/chomper pd init/, error.message)
    end

    # Regression: intake writes into the CANONICAL store, so mirroring the
    # working copy back over it on the way out (persist!) deleted every file
    # intake had just produced — the command reported success and left nothing
    # on disk.
    def test_intake_output_survives_and_reaches_the_working_copy
      store  = seeded_store
      runner = ProductRunner.new(@ctx, op: Object.new, intake: FakeIntake.new)
      runner.intake("42", "add-x")

      intake = store.change_dir("add-x") / "intake"
      assert (intake / "001-doc.md").exist?, "the intake document must survive the command"
      assert (store.change_dir("add-x") / "tracker.json").exist?
      assert (store.working_change_dir("add-x") / "intake" / "001-doc.md").exist?,
             "and reach the clone, where Claude reads it"
    end

    def test_intake_records_the_identity_it_short_circuits_on_next_time
      seeded_store
      state = ProductRunner.new(@ctx, op: Object.new, intake: FakeIntake.new)
                           .intake("42", "add-x", "--doc-id", "317")
                           .then { change_state("add-x") }

      assert_equal "sha256:fake", state.tracker.dig("intake", "hash")
      assert_equal %w[317], state.tracker.dig("intake", "selection")
      assert_equal "42", state.tracker["project_id"]
    end

    # Seed the store by hand rather than through setup!, which shells out to the
    # openspec CLI (not on PATH outside the runner image).
    def seeded_store
      store = ChangeStore.new(@ctx, @repo)
      store.tree.mkpath
      (store.tree / "config.yaml").write("schema: spec-driven\n")
      store
    end

    def change_state(change_id)
      ChangeState.new(change_id: change_id, store: seeded_store,
                      state_dir: Helpers.change_dir(@ctx, change_id))
    end

    # Stands in for Intake: writes where the real one writes (the canonical
    # store) and reports a change, which is all the runner's plumbing depends on.
    class FakeIntake
      def fetch(state, project_id:, doc_ids: [])
        dir = state.intake_dir
        dir.mkpath
        (dir / "001-doc.md").write("# Read-only mode\n")
        Intake::Result.new(changed: true, hash: "sha256:fake", unconvertible: [],
                           documents: [{ "id" => 317, "title" => "Read-only mode",
                                         "updatedAt" => "2026-08-02T22:07:56.784Z" }])
      end
    end

    def test_unknown_subcommand_lists_the_real_ones
      error = assert_raises(Chomper::FatalError) { @runner.run(["nope"]) }
      assert_match(/unknown pd subcommand/, error.message)
      assert_match(/init <project-id>/, error.message)
      assert_match(/intake <project-id> <change-id>/, error.message)
    end

    def test_missing_positional_arguments_are_reported
      assert_raises(Chomper::FatalError) { @runner.run(["init"]) }
      assert_raises(Chomper::FatalError) { @runner.run(["intake", "42"]) }
    end

    # The pd pipeline always publishes as the contributor bot, even if a
    # maintainer token somehow reached it — the CLI guard must never be the only
    # thing between pd and a canonical push.
    def test_publish_identity_is_contributor_regardless_of_tokens
      saved = ENV["GITHUB_MAINTAINER_TOKEN"]
      ENV["GITHUB_MAINTAINER_TOKEN"] = "maintainer-token"
      begin
        ctx = Context.build(@tmpdir)
        publish = ProductRunner.new(ctx, op: Object.new, intake: Object.new).send(:publish)
        assert_equal :contributor, publish.instance_variable_get(:@as)
      ensure
        saved.nil? ? ENV.delete("GITHUB_MAINTAINER_TOKEN") : ENV["GITHUB_MAINTAINER_TOKEN"] = saved
      end
    end
  end

  class CLIProductGuardTest < Minitest::Test
    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @saved  = ENV["GITHUB_MAINTAINER_TOKEN"]
    end

    def teardown
      @saved.nil? ? ENV.delete("GITHUB_MAINTAINER_TOKEN") : ENV["GITHUB_MAINTAINER_TOKEN"] = @saved
      FileUtils.rm_rf(@tmpdir)
    end

    # Direct-publish mode pushes straight to the canonical repo. Every pd stage
    # assumes the contributor fork instead, so the whole namespace refuses to
    # start rather than discovering the mismatch at push time.
    def test_pd_refuses_to_run_in_direct_publish_mode
      ENV["GITHUB_MAINTAINER_TOKEN"] = "maintainer-token"
      cli = CLI.new(Context.build(@tmpdir))

      %w[init intake propose generate-wp implement archive].each do |sub|
        error = assert_raises(Chomper::FatalError) { cli.run(["pd", sub, "42", "add-x"]) }
        assert_match(/GITHUB_MAINTAINER_TOKEN/, error.message)
        assert_match(/contributor bot/, error.message)
      end
    end

    def test_the_guard_fires_before_any_config_or_network_work
      ENV["GITHUB_MAINTAINER_TOKEN"] = "maintainer-token"
      ctx = Context.build(@tmpdir)
      # load_config! would raise its own "Config not found" without a URL/token;
      # seeing the maintainer message proves the guard ran first.
      error = assert_raises(Chomper::FatalError) { CLI.new(ctx).run(["pd", "init", "42"]) }
      refute_match(/Config not found/, error.message)
    end
  end
end
