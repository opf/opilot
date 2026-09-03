require_relative "../test_helper"
require "tmpdir"
require "stringio"

module OPilot
  class ChatRunnerTest < Minitest::Test
    # Records every prompt + the session file it was threaded with, and returns a
    # canned reply (the real Harness#run streams/renders; here we just capture).
    class RecordingHarness
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

    include TestFixtures

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx    = build_ctx(@tmpdir, host: "test.host")
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

    def test_empty_first_line_exits_without_calling_harness
      harness = RecordingHarness.new
      with_stdin("\n") { silently { ChatRunner.new(@ctx, harness: harness).run } }
      assert_empty harness.prompts, "an empty prompt must not reach the LLM"
    end

    def test_loops_until_blank_line_and_threads_one_session
      harness = RecordingHarness.new
      with_stdin("what's planned?\nsummarise it\n\n") do
        silently { ChatRunner.new(@ctx, harness: harness).run }
      end

      assert_equal 2, harness.prompts.length, "each non-empty line is one turn"
      assert_equal Harness::TOOLS_READ, harness.tools, "chat is read-only"
      # Both turns thread the same fresh per-run session file.
      session = @ctx.state_dir / "chat_session_id"
      assert_equal [session, session], harness.session_files
      assert_includes harness.prompts.first, "/state", "the prompt orients the LLM at the mirror root"
      assert_includes harness.prompts.first, "what's planned?"
      assert_includes harness.prompts.last,  "summarise it"
    end

    def test_the_orientation_is_sent_once_and_follow_ups_are_the_bare_message
      # It runs to about 1000 tokens — where the mirrors live, which repos
      # exist, how to reply. Every turn after the first resumes the same pi
      # session, which still holds all of it, so re-sending it per turn only
      # grew the context by that much per question.
      harness = RecordingHarness.new
      with_stdin("what's planned?\nsummarise it\nand again\n\n") do
        silently { ChatRunner.new(@ctx, harness: harness).run }
      end

      assert_equal 3, harness.prompts.length
      assert_includes harness.prompts.first, "/state"
      assert_equal "summarise it", harness.prompts[1]
      assert_equal "and again",    harness.prompts[2]
    end

    def test_inline_initial_message_is_the_first_turn
      harness = RecordingHarness.new
      with_stdin("\n") do  # nothing typed after the seeded message → exit
        silently { ChatRunner.new(@ctx, harness: harness).run("status of #42") }
      end
      assert_equal 1, harness.prompts.length
      assert_includes harness.prompts.first, "status of #42"
    end

    def test_op_mcp_flag_adds_op_query_to_the_grant
      stub_request(:get, "http://mcp-gw:47293/tools")
        .to_return(status: 200, body: JSON.generate({ result: { tools: [] } }))
      ctx = build_ctx(@tmpdir, host: "test.host", op_mcp: true, mcp_gw_url: "http://mcp-gw:47293", gw_token: "gw")
      harness = RecordingHarness.new
      with_stdin("hi\n\n") { silently { ChatRunner.new(ctx, harness: harness).run } }
      assert_equal Harness::TOOLS_READ_OP, harness.tools
    end

    def test_op_mcp_flag_survives_an_instance_with_no_mcp_server
      # The normal case now that Context#op_mcp? defaults on: most instances
      # have no Enterprise MCP add-on. The run must still complete — this is
      # never a reason to fail.
      stub_request(:get, "http://mcp-gw:47293/tools").to_return(status: 404, body: "MCP server is not available.")
      ctx = build_ctx(@tmpdir, host: "test.host", op_mcp: true, mcp_gw_url: "http://mcp-gw:47293", gw_token: "gw")
      harness = RecordingHarness.new
      with_stdin("hi\n\n") { silently { ChatRunner.new(ctx, harness: harness).run } }
      assert_equal 1, harness.prompts.length, "the chat still runs"
      assert_equal Harness::TOOLS_READ_OP, harness.tools, "the grant does not depend on the tool actually working"
    end

    def test_stale_session_file_is_cleared_at_start
      session = @ctx.state_dir / "chat_session_id"
      session.write("old-session-id")
      harness = RecordingHarness.new
      with_stdin("\n") { silently { ChatRunner.new(@ctx, harness: harness).run } }
      refute session.exist?, "a previous run's session must not be resumed"
    end
  end
end
