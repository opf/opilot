require_relative "../../test_helper"
require "tmpdir"

module OPilot
  class Matrix::PullTest < Minitest::Test
    ROOM = "!room:localhost"
    BOT  = "@opilot:localhost"
    YOU  = "@you:localhost"

    Ctx = Struct.new(:state_dir, :log_file, :matrix_host, :matrix_room_id, :allowed_matrix_users, keyword_init: true)

    class FakeClient
      attr_accessor :responses, :syncs
      def initialize(responses) = (@responses = responses; @syncs = [])
      def whoami = BOT
      def display_name(_) = "OPilot Bot"
      def joined_rooms = [ROOM]
      def sync(since:, filter:)
        @syncs << { since: since, filter: filter }
        @responses.shift
      end
    end

    def setup
      @dir = Pathname(Dir.mktmpdir)
      @ctx = Ctx.new(state_dir: @dir, log_file: @dir / "log", matrix_host: "localhost_8008",
                     matrix_room_id: ROOM, allowed_matrix_users: [YOU])
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def batch(token, *events)
      { "next_batch" => token, "rooms" => { "join" => { ROOM => { "timeline" => { "events" => events } } } } }
    end

    def msg(body, id: "$e1", sender: YOU, msgtype: "m.text", mentions: nil)
      content = { "msgtype" => msgtype, "body" => body }
      content["m.mentions"] = { "user_ids" => mentions } if mentions
      { "type" => "m.room.message", "event_id" => id, "sender" => sender, "content" => content }
    end

    # Starts past the first sync, so later calls see real events.
    def pull_with(*events)
      client = FakeClient.new([batch("s1"), batch("s2", *events)])
      pull = Matrix::Pull.new(@ctx, client: client)
      capture_io { assert_empty pull.poll_intents }
      [pull, client]
    end

    def poll(pull)
      result = nil
      out, = capture_io { result = pull.poll_intents }
      [result, out]
    end

    def test_the_first_sync_answers_nothing_and_stores_the_token
      client = FakeClient.new([batch("s1", msg("@opilot health 1"))])
      pull = Matrix::Pull.new(@ctx, client: client)
      intents, = poll(pull)
      assert_empty intents
      assert_equal "s1", JSON.parse(pull.state_file.read)["next_batch"]
      assert_equal [ROOM], client.syncs.first[:filter].dig("room", "rooms")
    end

    def test_a_display_name_prefix_addresses_opilot
      pull, = pull_with(msg("OPilot Bot: health #1323 proj-7"))
      intents, = poll(pull)
      assert_equal 1, intents.length
      assert_equal :health, intents.first.verb
      assert_equal %w[1323 PROJ-7], intents.first.ids
    end

    def test_an_at_localpart_prefix_addresses_opilot
      pull, = pull_with(msg("@opilot health 5"))
      assert_equal ["5"], poll(pull).first.first.ids
    end

    def test_m_mentions_addresses_opilot
      pull, = pull_with(msg("health 5", mentions: [BOT]))
      assert_equal :health, poll(pull).first.first.verb
    end

    def test_a_mention_only_reply_is_chat
      pull, = pull_with(msg("what does finding 2 mean?", mentions: [BOT]))
      assert_equal :chat, poll(pull).first.first.verb
    end

    def test_chat_names_its_work_packages
      pull, = pull_with(msg("@opilot compare #1323 and PROJ-7 with UTF-8, not 42"))
      intent = poll(pull).first.first
      assert_equal :chat, intent.verb
      assert_equal %w[1323 PROJ-7 UTF-8], intent.ids
    end

    def test_a_thread_message_keeps_the_thread_root
      thread = msg("@opilot and then?", id: "$e2")
      thread["content"]["m.relates_to"] = { "rel_type" => "m.thread", "event_id" => "$root" }
      pull, = pull_with(msg("@opilot hi"), thread)
      assert_equal %w[$e1 $root], poll(pull).first.map(&:thread_root)
    end

    def test_a_session_file_per_thread
      pull = Matrix::Pull.new(@ctx, client: FakeClient.new([]))
      refute_equal pull.session_file("$a"), pull.session_file("$b")
      assert_equal "_a-B_1", pull.session_file("$a-B:1").basename.to_s
    end

    def test_the_tick_counts_the_synced_messages
      pull, = pull_with(msg("not for opilot"), msg("@opilot hi", id: "$e2"))
      poll(pull)
      assert_equal 2, pull.event_count
    end

    def test_ensure_joined_refuses_a_room_the_bot_is_not_in
      pull = Matrix::Pull.new(@ctx, client: FakeClient.new([]))
      def (pull.client).joined_rooms = ["!other:localhost"]
      e = assert_raises(OPilot::FatalError) { pull.ensure_joined! }
      assert_includes e.message, ROOM
      assert_includes e.message, "Joined: !other:localhost"
    end

    def test_a_message_not_for_opilot_is_ignored
      pull, = pull_with(msg("health 5"), msg("opilotx health 5", id: "$e2"))
      assert_empty poll(pull).first
    end

    def test_own_messages_and_notices_are_ignored
      pull, = pull_with(msg("@opilot health 5", sender: BOT),
                        msg("@opilot health 5", id: "$e2", msgtype: "m.notice"))
      assert_empty poll(pull).first
    end

    def test_a_sender_outside_the_allowlist_is_ignored_and_logged
      pull, = pull_with(msg("@opilot health 5", sender: "@eve:evil.org"))
      intents, out = poll(pull)
      assert_empty intents
      assert_includes out, "@eve:evil.org"
    end

    def test_a_handled_event_is_not_returned_again
      client = FakeClient.new([batch("s1"), batch("s2", msg("@opilot health 5")),
                               batch("s3", msg("@opilot health 5"))])
      pull = Matrix::Pull.new(@ctx, client: client)
      capture_io { pull.poll_intents }
      assert_equal 1, poll(pull).first.length
      pull.mark_handled("$e1")
      assert_empty poll(pull).first
    end

    def test_the_token_advances_only_on_commit
      pull, client = pull_with(msg("@opilot health 5"))
      poll(pull)
      assert_equal "s1", JSON.parse(pull.state_file.read)["next_batch"]
      pull.commit_batch
      assert_equal "s2", JSON.parse(pull.state_file.read)["next_batch"]
      client.responses << batch("s3")
      poll(pull)
      assert_equal "s2", client.syncs.last[:since]
    end

    def test_an_encrypted_room_warns_once
      enc = { "type" => "m.room.encrypted", "event_id" => "$x", "sender" => YOU, "content" => {} }
      client = FakeClient.new([batch("s1"), batch("s2", enc, enc.merge("event_id" => "$y"))])
      pull = Matrix::Pull.new(@ctx, client: client)
      capture_io { pull.poll_intents }
      intents, out = poll(pull)
      assert_empty intents
      assert_equal 1, out.scan("is encrypted").length
    end

    def test_an_empty_message_and_bad_ids_are_unknown_with_a_reason
      pull, = pull_with(msg("@opilot"), msg("@opilot health nope", id: "$e2"),
                        msg("@opilot health", id: "$e3"), msg("@opilot health 1 2 3 4 5 6", id: "$e4"))
      intents, = poll(pull)
      assert_equal [:unknown] * 4, intents.map(&:verb)
      assert_nil intents[0].problem
      assert_includes intents[1].problem, "needs a work-package id first"
      assert_includes intents[2].problem, "needs a work-package id first"
      assert_includes intents[3].problem, "at most"
    end

    def test_the_cli_is_never_reached
      pull, = pull_with(msg("@opilot reset"), msg("@opilot dev build 5", id: "$e2"))
      assert_equal [:chat, :chat], poll(pull).first.map(&:verb)
    end

    def test_health_takes_ids_then_a_focus
      pull, = pull_with(msg("@opilot health #1, proj-2 the status"))
      intent = poll(pull).first.first
      assert_equal [:health, %w[1 PROJ-2], "the status"], [intent.verb, intent.ids, intent.message]
    end

    def test_build_and_create_wp_take_one_id_then_the_rest
      pull, = pull_with(msg("@opilot build #5 2 but keep the toast"), msg("@opilot fix 6", id: "$e2"),
                        msg("@opilot create work package #7 for Rosanna's idea", id: "$e3"))
      ship, fix, create = poll(pull).first
      assert_equal [:ship, ["5"], "2 but keep the toast"], [ship.verb, ship.ids, ship.message]
      assert_equal [:ship, ["6"], ""], [fix.verb, fix.ids, fix.message]
      assert_equal [:create_wp, ["7"], "for Rosanna's idea"], [create.verb, create.ids, create.message]
    end

    def test_build_keeps_numbers_and_line_breaks_after_its_id
      pull, = pull_with(msg("@opilot build #5 1 2 3 4 5 6\nand keep the toast"))
      intent = poll(pull).first.first
      assert_equal [:ship, ["5"], "1 2 3 4 5 6\nand keep the toast"], [intent.verb, intent.ids, intent.message]
    end

    def test_a_command_without_an_id_says_so
      pull, = pull_with(msg("@opilot build the login page"), msg("@opilot create wp for x", id: "$e2"))
      build, create = poll(pull).first
      assert_equal [:unknown, :unknown], [build.verb, create.verb]
      assert_includes build.problem, "`build` needs a work-package id"
      assert_includes create.problem, "`create wp` needs a work-package id"
    end

    def test_a_lens_is_chat_on_its_work_package
      pull, = pull_with(msg("@opilot grill #42 the rollout"))
      intent = poll(pull).first.first
      assert_equal [:chat, ["42"]], [intent.verb, intent.ids]
      assert_includes intent.message, "stress-test"
      assert_includes intent.message, "Focus especially on: the rollout"
      assert_includes intent.message, "work package #42"
    end

    def test_a_reply_fallback_is_stripped
      pull, = pull_with(msg("> <@x:l> earlier\n> text\n\n@opilot health 9"))
      assert_equal ["9"], poll(pull).first.first.ids
    end
  end
end
