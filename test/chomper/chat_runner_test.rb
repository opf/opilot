require_relative "../test_helper"
require "tmpdir"
require "stringio"

module Chomper
  class ChatRunnerTest < Minitest::Test
    # Records every prompt + the session file it was threaded with, and returns a
    # canned reply (the real Claude#run streams/renders; here we just capture).
    class RecordingClaude
      attr_reader :prompts, :session_files

      def initialize; @prompts = []; @session_files = []; end

      def run(prompt, tools: nil, model: nil, session_file: nil)
        @tools = tools
        @prompts << prompt
        @session_files << session_file
        "ok"
      end

      attr_reader :tools
    end

    def setup
      @tmpdir   = Dir.mktmpdir
      state_dir = Pathname(@tmpdir) / ".chomper"
      state_dir.mkpath
      registry = Registry.build(script_dir: Pathname(@tmpdir), state_dir: state_dir, op_repo_path: @tmpdir)
      @ctx = Struct.new(:script_dir, :state_dir, :state_container, :log_file, :repos) do
        def op_host; "test.host"; end   # WP mirror namespace
      end.new(
        Pathname(@tmpdir), state_dir, "/state", Pathname(@tmpdir) / "chomp.log", registry
      )
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
      super
    end

    def with_stdin(text)
      old = $stdin
      $stdin = StringIO.new(text)
      yield
    ensure
      $stdin = old
    end

    def silently
      old = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = old
    end

    def test_empty_first_line_exits_without_calling_claude
      claude = RecordingClaude.new
      with_stdin("\n") { silently { ChatRunner.new(@ctx, claude: claude).run } }
      assert_empty claude.prompts, "an empty prompt must not reach Claude"
    end

    def test_loops_until_blank_line_and_threads_one_session
      claude = RecordingClaude.new
      with_stdin("what's planned?\nsummarise it\n\n") do
        silently { ChatRunner.new(@ctx, claude: claude).run }
      end

      assert_equal 2, claude.prompts.length, "each non-empty line is one turn"
      assert_equal Claude::TOOLS_READ, claude.tools, "chat is read-only"
      # Both turns thread the same fresh per-run session file.
      session = @ctx.state_dir / "chat_session_id"
      assert_equal [session, session], claude.session_files
      assert_includes claude.prompts.first, "/state", "the prompt orients Claude at the mirror root"
      assert_includes claude.prompts.first, "what's planned?"
      assert_includes claude.prompts.last,  "summarise it"
    end

    def test_inline_initial_message_is_the_first_turn
      claude = RecordingClaude.new
      with_stdin("\n") do  # nothing typed after the seeded message → exit
        silently { ChatRunner.new(@ctx, claude: claude).run("status of #42") }
      end
      assert_equal 1, claude.prompts.length
      assert_includes claude.prompts.first, "status of #42"
    end

    def test_stale_session_file_is_cleared_at_start
      session = @ctx.state_dir / "chat_session_id"
      session.write("old-session-id")
      claude = RecordingClaude.new
      with_stdin("\n") { silently { ChatRunner.new(@ctx, claude: claude).run } }
      refute session.exist?, "a previous run's session must not be resumed"
    end
  end
end
