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

    def test_worktree_host_under_state_dir
      assert_equal @ctx.state_dir / "worktree", @ctx.worktree_host
    end

    def test_container_paths_are_fixed
      assert_equal "/repo",   @ctx.worktree_container
      assert_equal "/state",  @ctx.state_container
    end

    def test_load_config_raises_when_env_vars_missing
      saved = %w[OP_URL TOKEN REPO_PATH].map { |k| [k, ENV.delete(k)] }
      ctx = Context.build(@tmpdir)
      assert_raises(Chomper::FatalError) { ctx.load_config! }
    ensure
      saved.each { |k, v| ENV[k] = v if v }
    end
  end
end
