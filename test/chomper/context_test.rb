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
  end
end
