require_relative "../../test_helper"
require "tmpdir"

module OPilot
  class Matrix::AgentTest < Minitest::Test
    Ctx = Struct.new(:log_file, :allowed_matrix_users, :matrix_room_id, :configured, :state_dir,
                     :allowed_op_user_ids, keyword_init: true) do
      def op_mcp? = false
      def gh_mcp? = false
      def matrix? = configured != false
      def op_host = "op.test"
      def state_container = "/state"
      def repos = Struct.new(:all).new([])
    end

    # Stands in for the harness: records each prompt and opens the session.
    class FakeHarness
      attr_reader :runs
      def initialize(answer) = (@answer = answer; @runs = [])
      def run(prompt, session_file:, **)
        @runs << { prompt: prompt, session_file: session_file }
        session_file.write("sid")
        raise @answer if @answer.is_a?(Exception)
        @answer
      end
    end

    class FakeClient
      attr_reader :sent
      def initialize = @sent = []
      def typing(*, **) = true
      def react(*, **) = true
      def send_notice(room, body, txn_id:, reply_to:, thread_root:, mention:)
        @sent << { room: room, body: body, txn_id: txn_id, reply_to: reply_to, thread_root: thread_root, mention: mention }
      end
    end

    class FakePull
      attr_reader :client, :handled, :committed
      attr_accessor :intents
      def initialize(client, dir = nil) = (@client = client; @dir = dir; @handled = []; @committed = 0; @intents = [])
      def bot_id = "@opilot:localhost"
      def event_count = 3
      def session_file(root) = @dir / "session-#{root}"
      def ensure_bot_identity! = true
      def ensure_joined! = true
      def poll_intents = @intents
      def mark_handled(id) = @handled << id
      def commit_batch = @committed += 1
    end

    class FakeOpPull
      attr_reader :fetched
      def initialize = @fetched = []
      def ensure_bot_identity! = true
      def fetch_single_item(id)
        @fetched << id
        id == "404" ? nil : { "id" => id, "subject" => "Subject #{id}", "type" => "Bug" }
      end
    end

    class FakeHealth
      attr_reader :calls
      def initialize(&answer) = (@answer = answer; @calls = [])
      def run(id, focus:, internal:)
        @calls << [id, internal, focus]
        @answer.call(id)
      end
    end

    def setup
      @dir    = Pathname(Dir.mktmpdir)
      @ctx    = Ctx.new(log_file: @dir / "log", allowed_matrix_users: ["@you:localhost"], matrix_room_id: "!r:l",
                        state_dir: @dir, allowed_op_user_ids: ["7"])
      @client = FakeClient.new
      @pull   = FakePull.new(@client, @dir)
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # Records what OpenProject::Agent#handle_elsewhere is given, and posts `notes`.
    class FakeOpAgent
      attr_reader :calls
      def initialize(*notes) = (@notes = notes; @calls = [])
      def handle_elsewhere(intent, reply:, build_ref:)
        @calls << [intent, build_ref]
        @notes.each { |n| reply.call(intent.item_id, n) }
      end
    end

    def agent(health, harness: Object.new, op_pull: FakeOpPull.new, op_agent: FakeOpAgent.new)
      a = Matrix::Agent.new(@ctx, pull: @pull, harness: harness, op_pull: op_pull, health: health, op_agent: op_agent)
      a.define_singleton_method(:sync_bases_for_reading) { |*| nil }
      a
    end

    def intent(verb, ids = [], problem: nil, message: "", root: "$ev")
      Matrix::Intent.new(event_id: "$ev", sender: "@you:localhost", thread_root: root,
                         verb: verb, ids: ids, message: message, problem: problem)
    end

    def test_build_runs_the_openproject_handler_and_threads_its_notes
      op_agent = FakeOpAgent.new("I can fix this in 2 ways.", "Here is your prototype.")
      @pull.intents = [intent(:ship, ["5"], message: "2 keep the toast")]
      capture_io { agent(FakeHealth.new { nil }, op_agent: op_agent).tick }

      op_intent, build_ref = op_agent.calls.first
      assert_equal [:ship, "5", "Subject 5", "Bug", "2 keep the toast", "matrix:$ev", true],
                   [op_intent.command, op_intent.item_id, op_intent.subject, op_intent.type, op_intent.text,
                    op_intent.comment_at, op_intent.internal]
      assert_equal "#5", build_ref
      assert_equal ["I can fix this in 2 ways.", "Here is your prototype."], @client.sent.map { |s| s[:body] }
      assert_equal %w[opilot-$ev-1 opilot-$ev-2], @client.sent.map { |s| s[:txn_id] }
    end

    def test_create_wp_without_an_openproject_allowlist_is_refused_every_time
      @ctx.allowed_op_user_ids = []
      op_agent = FakeOpAgent.new
      @pull.intents = [intent(:create_wp, ["5"], message: "for x")]
      capture_io { agent(FakeHealth.new { nil }, op_agent: op_agent).tick }
      assert_empty op_agent.calls
      assert_equal OpenProject::CreateWp::DISABLED_NOTE, @client.sent.first[:body]
    end

    def test_create_wp_on_an_unreadable_work_package_is_answered
      op_agent = FakeOpAgent.new
      @pull.intents = [intent(:create_wp, ["404"], message: "for x")]
      capture_io { agent(FakeHealth.new { nil }, op_agent: op_agent).tick }
      assert_empty op_agent.calls
      assert_includes @client.sent.first[:body], "could not read work package #404"
    end

    def test_the_tick_is_logged_even_when_quiet
      out, = capture_io { agent(FakeHealth.new { nil }).tick }
      assert_includes out, "Polled Matrix (!r:l) — 3 message(s), 0 @opilot triggers"
    end

    def test_chat_orients_once_per_thread_then_follows_up
      harness = FakeHarness.new("An answer.")
      op_pull = FakeOpPull.new
      a = agent(FakeHealth.new { nil }, harness: harness, op_pull: op_pull)
      @pull.intents = [intent(:chat, %w[1323 404], message: "compare #1323 and #404", root: "$root")]
      capture_io { a.tick }
      @pull.intents = [intent(:chat, [], message: "and then?", root: "$root")]
      capture_io { a.tick }

      first, second = harness.runs.map { |r| r[:prompt].to_s }
      assert_includes first, "This is a chat in a Matrix room"
      assert_includes first, "/state/work_packages/op.test/1323/item.json"
      refute_includes first, "404/item.json"
      assert_includes first, "internal"
      assert_includes second, "@you:localhost asks: and then?"
      refute_includes second, "This is a chat in a Matrix room"
      assert_equal [@dir / "session-$root"] * 2, harness.runs.map { |r| r[:session_file] }
      assert_equal %w[1323 404], op_pull.fetched
      assert_equal "An answer.", @client.sent.first[:body]
      assert_equal "$root", @client.sent.first[:thread_root]
    end

    def test_a_failed_chat_is_answered
      a = agent(FakeHealth.new { nil }, harness: FakeHarness.new(Harness::Error.new("boom")))
      @pull.intents = [intent(:chat, message: "hi")]
      capture_io { a.tick }
      assert_includes @client.sent.first[:body], "did not finish"
    end

    def test_a_health_report_is_public_and_one_reply_per_id
      health = FakeHealth.new { |id| "**Health check: no findings.** #{id}" }
      @pull.intents = [intent(:health, %w[1 PROJ-2], message: "the status")]
      capture_io { agent(health).tick }

      assert_equal [["1", false, "the status"], ["PROJ-2", false, "the status"]], health.calls
      assert_equal %w[opilot-$ev-0 opilot-$ev-1], @client.sent.map { |s| s[:txn_id] }
      assert_match(/\A#1\n\n/, @client.sent[0][:body])
      assert(@client.sent.all? { |s| s[:reply_to] == "$ev" && s[:mention] == "@you:localhost" })
      assert_equal ["$ev"], @pull.handled
      assert_equal 1, @pull.committed
    end

    def test_an_unreadable_work_package_and_a_failed_run_are_answered
      health = FakeHealth.new { |id| id == "1" ? nil : raise(Harness::Error, "boom") }
      @pull.intents = [intent(:health, %w[1 2])]
      capture_io { agent(health).tick }
      assert_includes @client.sent[0][:body], "could not read work package #1"
      assert_includes @client.sent[1][:body], "did not finish"
    end

    def test_an_unknown_command_gets_the_help_reply
      @pull.intents = [intent(:unknown, problem: "nope is not a work-package id.")]
      capture_io { agent(FakeHealth.new { nil }).tick }
      body = @client.sent.first[:body]
      assert body.start_with?("nope is not a work-package id.")
      assert_includes body, "Ask me a question"
    end

    def test_a_long_report_is_cut
      @pull.intents = [intent(:health, ["1"])]
      capture_io { agent(FakeHealth.new { "x" * 70_000 }).tick }
      body = @client.sent.first[:body]
      assert_operator body.bytesize, :<, 61_000
      assert_includes body, "It stops here."
    end

    def test_a_handler_error_is_logged_and_acked
      @pull.intents = [intent(:health, ["1"])]
      def @client.send_notice(*, **) = raise(Clients::Matrix::Error, "down")
      out, = capture_io { agent(FakeHealth.new { "ok" }).tick }
      assert_includes out, "down"
      assert_equal ["$ev"], @pull.handled
    end

    def test_a_crashed_handler_is_answered
      op_agent = FakeOpAgent.new
      def op_agent.handle_elsewhere(*, **) = raise(RuntimeError, "git push failed")
      @pull.intents = [intent(:ship, ["5"])]
      capture_io { agent(FakeHealth.new { nil }, op_agent: op_agent).tick }
      assert_includes @client.sent.last[:body], "I could not finish this (RuntimeError)"
      assert_equal "opilot-$ev-error", @client.sent.last[:txn_id]
    end

    def test_setup_refuses_without_the_matrix_config
      @ctx.configured = false
      e = assert_raises(OPilot::FatalError) { agent(FakeHealth.new { nil }).setup }
      assert_includes e.message, "MATRIX_ROOM_ID"
    end

    def test_setup_refuses_without_an_allowlist
      @ctx.allowed_matrix_users = []
      e = assert_raises(OPilot::FatalError) { agent(FakeHealth.new { nil }).setup }
      assert_includes e.message, "OPILOT_ALLOWED_MATRIX_USERS"
    end
  end
end
