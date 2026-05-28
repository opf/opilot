require_relative "../test_helper"

module Chomper
  class FixTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @state_dir = Pathname(@tmpdir) / ".chomper"
      @ctx = Struct.new(:state_dir, :state_container, :log_file, :script_dir).new(
        @state_dir, "/state", Pathname("/dev/null"), Pathname(@tmpdir)
      )
      @fix = Fix.new(@ctx, nil, nil)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    ITEM = {
      "subject"        => "Fix the login bug",
      "locality_group" => "auth",
      "complexity"     => "simple",
      "url"            => "https://example.com/work_packages/42",
      "files_touched"  => ["app/auth.rb", "app/session.rb"]
    }.freeze

    def test_container_path_replaces_state_dir_prefix
      host_path = @state_dir / "items" / "42" / "plan.md"
      result = @fix.send(:container_path, host_path)
      assert_equal "/state/items/42/plan.md", result
    end

    def test_container_path_preserves_nested_structure
      host_path = @state_dir / "deep" / "a" / "b" / "c.txt"
      result = @fix.send(:container_path, host_path)
      assert_equal "/state/deep/a/b/c.txt", result
    end

    def test_build_fix_state_item_id_as_string
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal "42", fs.item_id
    end

    def test_build_fix_state_item_id_coerced_from_integer
      fs = @fix.send(:build_fix_state, 42, ITEM)
      assert_equal "42", fs.item_id
    end

    def test_build_fix_state_title_from_subject
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal "Fix the login bug", fs.title
    end

    def test_build_fix_state_group_and_complexity
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal "auth",   fs.group
      assert_equal "simple", fs.complexity
    end

    def test_build_fix_state_branch_starts_with_fix_prefix_and_id
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_match(/^fix\/42-/, fs.branch)
    end

    def test_build_fix_state_branch_is_lowercase_no_special_chars
      fs = @fix.send(:build_fix_state, "42", ITEM)
      refute_match(/[^a-z0-9\-\/]/, fs.branch)
    end

    def test_build_fix_state_item_dir_under_state_dir
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal @state_dir / "items" / "42", fs.item_dir
    end

    def test_build_fix_state_plan_file_under_item_dir
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal fs.item_dir / "plan.md", fs.plan_file
    end

    def test_build_fix_state_item_file_under_item_dir
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal fs.item_dir / "item.json", fs.item_file
    end

    def test_build_fix_state_joins_files_hint_with_comma
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal "app/auth.rb, app/session.rb", fs.files_hint
    end

    def test_build_fix_state_empty_files_touched_gives_empty_hint
      item = ITEM.merge("files_touched" => [])
      fs = @fix.send(:build_fix_state, "42", item)
      assert_equal "", fs.files_hint
    end

    def test_build_fix_state_url_preserved
      fs = @fix.send(:build_fix_state, "42", ITEM)
      assert_equal "https://example.com/work_packages/42", fs.url
    end

    # ── request_approval ──────────────────────────────────────────────────────

    def with_stdin(input)
      old = $stdin
      $stdin = StringIO.new(input)
      yield
    ensure
      $stdin = old
    end

    FakeBacklog = Struct.new(:last_id, :last_state) do
      def set_state(id, state)
        self.last_id    = id
        self.last_state = state
      end
    end

    def approval_fixture
      fs = @fix.send(:build_fix_state, "42", ITEM)
      fs.item_dir.mkpath
      fs.plan_file.write("## Plan\nDo the thing.\n")
      backlog = FakeBacklog.new
      fix = Fix.new(@ctx, backlog, nil)
      [fix, fs, backlog]
    end

    def test_request_approval_returns_approved_on_y
      fix, fs, _backlog = approval_fixture
      with_stdin("y\n") { assert_equal :approved, fix.send(:request_approval, fs) }
    end

    def test_request_approval_returns_approved_on_enter
      fix, fs, _backlog = approval_fixture
      with_stdin("\n") { assert_equal :approved, fix.send(:request_approval, fs) }
    end

    def test_request_approval_reprompts_on_gibberish_then_approves
      fix, fs, _backlog = approval_fixture
      with_stdin("what?\ny\n") { assert_equal :approved, fix.send(:request_approval, fs) }
    end

    def test_request_approval_returns_rejected_on_n
      fix, fs, backlog = approval_fixture
      with_stdin("n\n") do
        result = fix.send(:request_approval, fs)
        assert_equal :rejected, result
        refute fs.plan_file.exist?
        assert_equal Backlog::STATE_PENDING, backlog.last_state
      end
    end

    def test_request_approval_returns_skipped_on_skip
      fix, fs, backlog = approval_fixture
      with_stdin("skip\n") do
        result = fix.send(:request_approval, fs)
        assert_equal :skipped, result
        assert fs.plan_file.exist?
        assert_equal Backlog::STATE_PLANNED, backlog.last_state
      end
    end
  end
end
