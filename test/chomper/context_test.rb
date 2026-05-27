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

    def test_load_config_raises_without_file
      assert_raises(RuntimeError) { @ctx.load_config! }
    end

    def test_write_and_load_config_round_trip
      @ctx.write_config!(
        op_url:     "https://community.openproject.org",
        token:      "secret123",
        project_id: "my-project",
        repo_path:  "/repos/openproject"
      )
      @ctx.load_config!
      assert_equal "https://community.openproject.org", @ctx.op_url
      assert_equal "secret123",   @ctx.token
      assert_equal "my-project",  @ctx.project_id
      assert_equal Pathname("/repos/openproject"), @ctx.repo_path
    end

    def test_write_config_escapes_double_quotes_in_token
      @ctx.write_config!(
        op_url:     "https://example.com",
        token:      'abc"def',
        project_id: "proj",
        repo_path:  "/repos/foo"
      )
      @ctx.load_config!
      assert_equal 'abc"def', @ctx.token
    end

    def test_config_file_is_chmod_600
      @ctx.write_config!(op_url: "u", token: "t", project_id: "p", repo_path: "/r")
      mode = @ctx.config_file.stat.mode & 0o777
      assert_equal 0o600, mode
    end
  end
end
