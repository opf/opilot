require_relative "../../test_helper"

module OPilot
  class Clients::MatrixTest < Minitest::Test
    HS = "http://matrix.test:8008"
    API = "#{HS}/_matrix/client/v3"

    def setup
      @client = Clients::Matrix.new(HS, "syt_secret")
    end

    def test_whoami_sends_a_bearer_token_and_never_a_query_token
      stub_request(:get, "#{API}/account/whoami")
        .with(headers: { "Authorization" => "Bearer syt_secret" })
        .to_return(status: 200, body: '{"user_id":"@opilot:localhost"}')
      assert_equal "@opilot:localhost", @client.whoami
      assert_not_requested(:get, /access_token/)
    end

    def test_sync_passes_since_and_an_inline_filter
      stub_request(:get, %r{#{API}/sync\?}).to_return(status: 200, body: '{"next_batch":"s2"}')
      assert_equal "s2", @client.sync(since: "s1", filter: { "room" => {} })["next_batch"]
      assert_requested(:get, %r{/sync\?}) do |req|
        q = URI.decode_www_form(req.uri.query).to_h
        q["since"] == "s1" && q["timeout"] == "0" && JSON.parse(q["filter"]) == { "room" => {} }
      end
    end

    def test_send_notice_is_a_threaded_notice_with_a_mention
      stub_request(:put, "#{API}/rooms/%21r%3Alocalhost/send/m.room.message/opilot-%24ev-0")
        .to_return(status: 200, body: '{"event_id":"$reply"}')
      id = @client.send_notice("!r:localhost", "hi", txn_id: "opilot-$ev-0", reply_to: "$ev", mention: "@you:localhost")
      assert_equal "$reply", id
      assert_requested(:put, /send/) do |req|
        body = JSON.parse(req.body)
        body["msgtype"] == "m.notice" && body["body"] == "hi" &&
          body.dig("m.relates_to", "m.in_reply_to", "event_id") == "$ev" &&
          body.dig("m.mentions", "user_ids") == ["@you:localhost"]
      end
    end

    def test_send_notice_in_a_thread
      stub_request(:put, %r{/send/}).to_return(status: 200, body: '{"event_id":"$r"}')
      @client.send_notice("!r:l", "hi", txn_id: "t", reply_to: "$ev", thread_root: "$root")
      assert_requested(:put, /send/) do |req|
        rel = JSON.parse(req.body)["m.relates_to"]
        rel["rel_type"] == "m.thread" && rel["event_id"] == "$root" && rel["is_falling_back"] == true &&
          rel.dig("m.in_reply_to", "event_id") == "$ev"
      end
    end

    def test_an_error_names_the_errcode_but_not_the_token
      stub_request(:get, "#{API}/account/whoami")
        .to_return(status: 401, body: '{"errcode":"M_UNKNOWN_TOKEN","error":"Invalid token"}')
      e = assert_raises(Clients::Matrix::Error) { @client.whoami }
      assert_includes e.message, "M_UNKNOWN_TOKEN"
      refute_includes e.message, "syt_secret"
    end

    def test_a_5xx_is_retried
      stub_request(:get, "#{API}/account/whoami")
        .to_return({ status: 502 }, { status: 200, body: '{"user_id":"@o:l"}' })
      capture_io { assert_equal "@o:l", @client.whoami }
    end

    def test_a_network_failure_is_a_matrix_error
      stub_request(:get, "#{API}/account/whoami").to_raise(SocketError.new("no route"))
      capture_io { assert_raises(Clients::Matrix::Error) { @client.whoami } }
    end

    def test_joined_rooms
      stub_request(:get, "#{API}/joined_rooms").to_return(status: 200, body: '{"joined_rooms":["!r:l"]}')
      assert_equal ["!r:l"], @client.joined_rooms
    end

    def test_react_sends_an_annotation
      stub_request(:put, "#{API}/rooms/%21r%3Al/send/m.reaction/t").to_return(status: 200, body: "{}")
      assert @client.react("!r:l", "$ev", "👀", txn_id: "t")
      assert_requested(:put, /m.reaction/) do |req|
        JSON.parse(req.body)["m.relates_to"] == { "rel_type" => "m.annotation", "event_id" => "$ev", "key" => "👀" }
      end
    end

    def test_typing_is_best_effort
      stub_request(:put, %r{/typing/}).to_return(status: 403, body: "{}")
      refute @client.typing("!r:l", "@o:l")
    end
  end
end
