require_relative "../test_helper"

module Chomper
  class ContextTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = Context.build(@tmpdir)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_script_dir_set_from_argument
      assert_equal Pathname(@tmpdir), @ctx.script_dir
    end

    def test_state_dir_is_dotchomper_under_script_dir
      assert_equal Pathname(@tmpdir) / ".chomper", @ctx.state_dir
    end

    def test_state_container_is_fixed
      assert_equal "/state", @ctx.state_container
    end

    def test_default_repo_comes_from_the_registry
      # With no repos.json in the tmpdir, the registry falls back to a single
      # openproject entry; its checkout lives under .chomper/repos/<name>.
      assert_equal "openproject", @ctx.default_repo.name
      assert_equal @ctx.state_dir / "repos" / "openproject", @ctx.default_repo.worktree_host
      assert_equal "/repos/openproject", @ctx.default_repo.worktree_container
    end

    def test_load_config_raises_when_env_vars_missing
      saved = %w[OPENPROJECT_URL OPENPROJECT_TOKEN].map { |k| [k, ENV.delete(k)] }
      ctx = Context.build(@tmpdir)
      assert_raises(Chomper::FatalError) { ctx.load_config! }
    ensure
      saved.each { |k, v| ENV[k] = v if v }
    end

    def test_op_host_is_a_filesystem_safe_segment_from_the_url
      with_env("OPENPROJECT_URL" => "https://Community.OpenProject.org") do
        assert_equal "community.openproject.org", Context.build(@tmpdir).op_host
      end
      # A non-default port is folded in so two local instances don't collide.
      with_env("OPENPROJECT_URL" => "http://localhost:8080") do
        assert_equal "localhost_8080", Context.build(@tmpdir).op_host
      end
      # Standard ports are dropped; a blank URL falls back to a safe sentinel.
      with_env("OPENPROJECT_URL" => "https://op.example.com:443") do
        assert_equal "op.example.com", Context.build(@tmpdir).op_host
      end
      with_env("OPENPROJECT_URL" => nil) { assert_equal "unknown-host", Context.build(@tmpdir).op_host }
    end

    def test_force_fork_overrides_direct_pr_mode
      with_env("CHOMPER_PR_MODE" => "direct") do
        ctx = Context.build(@tmpdir)
        assert ctx.direct_pr?, "sanity: env selects direct mode"
        ctx.force_fork!
        refute ctx.direct_pr?, "force_fork! must pin publishing to fork mode"
      end
    end

    def test_assign_trigger_is_on_by_default_and_opt_out
      with_env("CHOMPER_ASSIGN_TRIGGER" => nil) { assert Context.build(@tmpdir).assign_trigger? }
      with_env("CHOMPER_ASSIGN_TRIGGER" => "1") { assert Context.build(@tmpdir).assign_trigger? }
      with_env("CHOMPER_ASSIGN_TRIGGER" => "0") { refute Context.build(@tmpdir).assign_trigger? }
      with_env("CHOMPER_ASSIGN_TRIGGER" => "false") { refute Context.build(@tmpdir).assign_trigger? }
    end

    def test_ci_max_attempts_defaults_to_five_and_is_floored_at_one
      with_env("CHOMPER_CI_MAX_ATTEMPTS" => nil) { assert_equal 5, Context.build(@tmpdir).ci_max_attempts }
      with_env("CHOMPER_CI_MAX_ATTEMPTS" => "3") { assert_equal 3, Context.build(@tmpdir).ci_max_attempts }
      with_env("CHOMPER_CI_MAX_ATTEMPTS" => "0") { assert_equal 1, Context.build(@tmpdir).ci_max_attempts }
    end

    def test_ci_ignored_checks_defaults_to_saas_tests_and_is_overridable
      with_env("CHOMPER_CI_IGNORE_CHECKS" => nil) { assert_equal ["saas tests"], Context.build(@tmpdir).ci_ignored_checks }
      with_env("CHOMPER_CI_IGNORE_CHECKS" => "Foo, Bar") { assert_equal ["foo", "bar"], Context.build(@tmpdir).ci_ignored_checks }
      with_env("CHOMPER_CI_IGNORE_CHECKS" => "") { assert_equal [], Context.build(@tmpdir).ci_ignored_checks }
    end

    private

    def with_env(vars)
      saved = vars.map { |k, _| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
