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
