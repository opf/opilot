require_relative "../test_helper"
require "tmpdir"

module Chomper
  class ClaudeTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      ctx = Struct.new(:claude_url, :log_file)
              .new("http://claude.test:47291", Pathname(@tmpdir) / "chomp.log")
      @claude = Claude.new(ctx)
      @session_file = Pathname(@tmpdir) / "session_id"
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
      super
    end

    def ndjson(*messages)
      messages.map { |m| JSON.generate(m) }.join("\n") + "\n"
    end

    def assistant_text(text)
      { type: "assistant", message: { content: [{ type: "text", text: text }] } }
    end

    def stub_claude(body)
      stub_request(:post, "http://claude.test:47291").to_return(status: 200, body: body)
    end

    def test_run_returns_streamed_text_on_success
      stub_claude(ndjson(
        assistant_text("the plan"),
        { type: "result", subtype: "success", is_error: false, result: "the plan" },
        { type: "session_id", session_id: "abc-123" }
      ))

      text = nil
      capture_io { text = @claude.run("prompt", session_file: @session_file) }

      assert_equal "the plan", text
      assert_equal "abc-123", @session_file.read
    end

    def test_run_raises_on_error_result
      stub_claude(ndjson(
        assistant_text("Let me look around."),
        { type: "result", subtype: "success", is_error: true,
          result: "Claude requested permissions to use Bash, but you haven't granted it" }
      ))

      err = nil
      out, = capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt") }
      end

      assert_match(/requested permissions to use Bash/, err.message)
      assert_includes out, "✗"
    end

    def test_run_raises_on_error_subtype_and_still_saves_session
      stub_claude(ndjson(
        { type: "result", subtype: "error_max_turns", is_error: false, result: "" },
        { type: "session_id", session_id: "def-456" }
      ))

      capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt", session_file: @session_file) }
        assert_equal "error_max_turns", err.message
      end

      assert_equal "def-456", @session_file.read, "a retry must be able to resume the session"
    end

    def test_run_raises_on_http_error_with_body
      stub_request(:post, "http://claude.test:47291")
        .to_return(status: 403, body: "unknown tool grant\n")

      capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt") }
        assert_match(/HTTP 403/, err.message)
        assert_match(/unknown tool grant/, err.message)
      end
    end

    def test_run_enriches_execution_error_with_stderr_tail
      stub_claude(ndjson(
        { type: "result", subtype: "error_during_execution", is_error: true, result: "" },
        { type: "exit", code: 1, signal: nil, timed_out: false,
          stderr: "API Error: 529 Overloaded" }
      ))

      capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt") }
        assert_match(/error_during_execution/, err.message)
        assert_match(/exit 1/, err.message)
        assert_match(/API Error: 529 Overloaded/, err.message)
      end
    end

    def test_run_treats_nonzero_exit_with_no_result_as_error
      stub_claude(ndjson(
        { type: "exit", code: 1, signal: nil, timed_out: false, stderr: "boom" }
      ))

      capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt") }
        assert_match(/exited 1 with no result/, err.message)
        assert_match(/boom/, err.message)
      end
    end

    def test_run_reports_timeout_kill
      stub_claude(ndjson(
        { type: "exit", code: nil, signal: "SIGTERM", timed_out: true, stderr: "" }
      ))

      capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt") }
        assert_match(/timed out/, err.message)
      end
    end

    def test_run_ignores_exit_event_on_success
      stub_claude(ndjson(
        assistant_text("the plan"),
        { type: "result", subtype: "success", is_error: false, result: "the plan" },
        { type: "exit", code: 0, signal: nil, timed_out: false, stderr: "some noise" }
      ))

      text = nil
      capture_io { text = @claude.run("prompt") }
      assert_equal "the plan", text
    end

    def test_run_retries_fresh_when_resumed_session_is_gone
      @session_file.write("dead-session-id")
      # First call (with --resume) fails: the CLI can't find the session. Second
      # call (fresh, no session) succeeds. WebMock replays responses in order.
      stub_request(:post, "http://claude.test:47291").to_return(
        { status: 200, body: ndjson(
          { type: "result", subtype: "error_during_execution", is_error: true, result: "" },
          { type: "exit", code: 1, signal: nil, timed_out: false,
            stderr: "No conversation found with session ID: dead-session-id" }) },
        { status: 200, body: ndjson(
          assistant_text("fresh answer"),
          { type: "result", subtype: "success", is_error: false, result: "fresh answer" },
          { type: "session_id", session_id: "new-session" }) }
      )

      text = nil
      out, = capture_io { text = @claude.run("prompt", session_file: @session_file) }

      assert_equal "fresh answer", text
      assert_equal "new-session", @session_file.read, "the recovered session id is saved"
      assert_match(/starting fresh/, out)
    end

    def test_run_does_not_retry_fresh_on_unrelated_error
      @session_file.write("live-session")
      stub_claude(ndjson(
        { type: "result", subtype: "error_during_execution", is_error: true, result: "" },
        { type: "exit", code: 1, signal: nil, timed_out: false, stderr: "API Error: 529 Overloaded" }
      ))

      capture_io do
        err = assert_raises(Claude::Error) { @claude.run("prompt", session_file: @session_file) }
        assert_match(/Overloaded/, err.message)
      end
      # Stubbed exactly one response; a spurious retry would raise a WebMock error.
    end

    def test_capture_does_not_write_outfile_on_error
      stub_claude(ndjson(
        assistant_text("partial preamble"),
        { type: "result", subtype: "error_during_execution", is_error: true, result: "boom" }
      ))
      outfile = Pathname(@tmpdir) / "plan.md"

      capture_io do
        assert_raises(Claude::Error) { @claude.capture("prompt", outfile: outfile) }
      end

      refute outfile.exist?, "a failed run must not leave partial text as the plan"
    end
  end
end
