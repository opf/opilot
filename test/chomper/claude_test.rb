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
