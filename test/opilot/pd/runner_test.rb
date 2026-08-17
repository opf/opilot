require_relative "../../test_helper"
require "tmpdir"

module OPilot
  module PD
    class RunnerTest < Minitest::Test
      def setup
        @tmpdir = Pathname(Dir.mktmpdir)
        @ctx    = Context.build(@tmpdir)
        @repo   = @ctx.default_repo
        (@repo.worktree_host / ".git" / "info").mkpath
        @runner = Runner.new(@ctx, op: Object.new, intake: Object.new)
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
        assert_raises(OPilot::FatalError) { options("--nope") }
        assert_raises(OPilot::FatalError) { options("--doc-id") }
        assert_raises(OPilot::FatalError) { options("--doc-id", "--repo") }
      end

      def test_change_ids_are_validated_not_sanitised
        # The change id becomes a directory name everything downstream binds to;
        # silently rewriting it would break the binding the operator thinks they
        # made, so a bad one is refused instead.
        %w[add-recurring-meetings a 9lives x-1-y].each do |good|
          @runner.send(:validate_change_id!, good)
        end
        ["Add-Thing", "add thing", "-leading", "add_thing", "../escape", ""].each do |bad|
          assert_raises(OPilot::FatalError, "#{bad.inspect} should be refused") do
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
          error = assert_raises(OPilot::FatalError, "#{bad.inspect} should be refused") do
            Runner.new(@ctx, op: Object.new, intake: FakeIntake.new).run(["intake", "42", bad])
          end
          assert_match(/invalid change id/, error.message)
        end
        refute (@ctx.state_dir / "openspec" / @repo.name / "openspec" / "changes").exist?,
               "a refused id must not have created anything"
      end

      def test_unknown_repo_names_are_reported_with_the_available_set
        error = assert_raises(OPilot::FatalError) { @runner.send(:resolve_repo, "nope") }
        assert_match(/unknown repo "nope"/, error.message)
        assert_match(/openproject/, error.message)
      end

      def test_repo_defaults_to_the_registry_default
        assert_equal @ctx.default_repo.name, @runner.send(:resolve_repo, nil).name
      end

      def test_intake_refuses_before_the_store_is_seeded
        error = assert_raises(OPilot::FatalError) { @runner.intake("42", "add-x") }
        assert_match(/run `\.\/opilot pd init/, error.message)
      end

      # Regression: intake writes into the CANONICAL store, so mirroring the
      # working copy back over it on the way out (persist!) deleted every file
      # intake had just produced — the command reported success and left nothing
      # on disk.
      def test_intake_output_survives_and_reaches_the_working_copy
        store  = seeded_store
        runner = Runner.new(@ctx, op: Object.new, intake: FakeIntake.new)
        runner.intake("42", "add-x")

        intake = store.change_dir("add-x") / "intake"
        assert (intake / "001-doc.md").exist?, "the intake document must survive the command"
        assert (store.change_dir("add-x") / "tracker.json").exist?
        assert (store.working_change_dir("add-x") / "intake" / "001-doc.md").exist?,
               "and reach the clone, where the LLM reads it"
      end

      def test_intake_records_the_identity_it_short_circuits_on_next_time
        seeded_store
        state = Runner.new(@ctx, op: Object.new, intake: FakeIntake.new)
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
        error = assert_raises(OPilot::FatalError) { @runner.run(["nope"]) }
        assert_match(/unknown pd subcommand/, error.message)
        assert_match(/init <project-id>/, error.message)
        assert_match(/intake <project-id> <change-id>/, error.message)
      end

      def test_missing_positional_arguments_are_reported
        assert_raises(OPilot::FatalError) { @runner.run(["init"]) }
        assert_raises(OPilot::FatalError) { @runner.run(["intake", "42"]) }
      end

      # --- init's preflight -------------------------------------------------

      def test_init_refuses_without_a_clone
        # ChangeStore#exclude_from_clone! returns silently when .git/info is
        # missing, so a half-provisioned clone would leave openspec/ sweepable into
        # an unrelated commit with nothing said. This is the one preflight where
        # quiet degradation is dangerous rather than merely late.
        FileUtils.rm_rf((@repo.worktree_host / ".git").to_s)
        error = assert_raises(OPilot::FatalError) { @runner.run(["init", "42"]) }

        assert_match(/No git clone for openproject/, error.message)
        assert_match(/Run `\.\/opilot`/, error.message)
      end

      def test_init_checks_the_clone_before_any_network_work
        # The OpenProject client here is an Object; reaching it would raise
        # NoMethodError instead of the clone message.
        FileUtils.rm_rf((@repo.worktree_host / ".git").to_s)
        error = assert_raises(OPilot::FatalError) { @runner.run(["init", "42"]) }
        assert_match(/No git clone/, error.message)
      end

      # Reports the publishing identity `propose` will use, rather than letting a
      # bad token surface at push time after the LLM has done the expensive work.
      class FakeIdentityPublish
        def initialize(login: "op-opilot", scopes: %w[public_repo workflow gist])
          @login = login
          @scopes = scopes
        end

        def login = @login.is_a?(StandardError) ? raise(@login) : @login
        def token_scopes = @scopes
      end

      def identity_output(publish, token: "tok")
        saved = ENV["GITHUB_CONTRIBUTOR_TOKEN"]
        ENV["GITHUB_CONTRIBUTOR_TOKEN"] = token
        ctx = Context.build(@tmpdir)
        run = Runner.new(ctx, op: Object.new, intake: Object.new, publish: publish)
        capture_io { run.send(:report_publish_identity) }.first
      ensure
        saved.nil? ? ENV.delete("GITHUB_CONTRIBUTOR_TOKEN") : ENV["GITHUB_CONTRIBUTOR_TOKEN"] = saved
      end

      def test_init_reports_the_publishing_identity
        out = identity_output(FakeIdentityPublish.new)
        assert_match(/✓ github\s+op-opilot \(scopes: public_repo, workflow, gist\)/, out)
      end

      def test_init_names_the_scopes_a_classic_token_is_missing
        out = identity_output(FakeIdentityPublish.new(scopes: %w[public_repo]))
        assert_match(/missing workflow, gist/, out)
      end

      def test_a_fine_grained_token_is_not_warned_about_classic_scopes
        # No X-OAuth-Scopes header means "unknown", not "no permissions".
        out = identity_output(FakeIdentityPublish.new(scopes: []))
        assert_match(/✓ github\s+op-opilot/, out)
        refute_match(/missing/, out)
      end

      def test_a_missing_or_broken_token_is_reported_but_not_fatal
        # init and intake are useful with no GitHub token at all.
        out = identity_output(FakeIdentityPublish.new, token: "")
        assert_match(/GITHUB_CONTRIBUTOR_TOKEN is not set/, out)

        broken = identity_output(FakeIdentityPublish.new(login: StandardError.new("401 Unauthorized")))
        assert_match(/could not verify GITHUB_CONTRIBUTOR_TOKEN \(401 Unauthorized\)/, broken)
      end

      # Like every other mode, pd publishes as the contributor bot — the only
      # identity opilot has.
      def test_publish_identity_is_the_contributor_bot
        saved = ENV["GITHUB_CONTRIBUTOR_TOKEN"]
        ENV["GITHUB_CONTRIBUTOR_TOKEN"] = "bot-token"
        begin
          ctx = Context.build(@tmpdir)
          publish = Runner.new(ctx, op: Object.new, intake: Object.new).send(:publish)
          assert_equal "bot-token", publish.author_token
          assert_equal "GITHUB_CONTRIBUTOR_TOKEN", publish.token_env_var
        ensure
          saved.nil? ? ENV.delete("GITHUB_CONTRIBUTOR_TOKEN") : ENV["GITHUB_CONTRIBUTOR_TOKEN"] = saved
        end
      end
    end
  end
end
