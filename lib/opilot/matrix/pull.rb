require "json"

module OPilot
  module Matrix
    # Reads the one configured Matrix room and turns messages addressed to
    # opilot into Matrix::Intents. Invites and every other room are ignored.
    #
    # State is .opilot/matrix/<host>/sync.json: the sync token, and the last
    # handled event ids. A crash replays one batch; the ids stop a second answer.
    class Pull
      include Helpers

      MAX_HANDLED = 200
      MAX_IDS = 5

      attr_reader :client, :bot_id, :event_count

      def initialize(ctx, client: Clients::Matrix.new(ctx.matrix_url, ctx.matrix_token))
        @ctx    = ctx
        @client = client
        @warned_encrypted = false
      end

      # Fails loudly before the loop starts, like OpenProject::Pull#ensure_bot_identity!.
      # Element's pill puts the display name in `body`, so it is a prefix too.
      def ensure_bot_identity!
        @bot_id = @client.whoami
        names = [@bot_id, "@#{@bot_id.delete_prefix("@").split(":").first}", @client.display_name(@bot_id)]
        alts = names.compact.reject(&:empty?).uniq.sort_by { |n| -n.length }.map { |n| Regexp.escape(n) }
        @prefix = /\A\s*(?:#{alts.join("|")})(?=[\s:,]|\z)[:,]?\s*/i
      rescue Clients::Matrix::Error => e
        raise OPilot::FatalError, "could not resolve opilot's Matrix identity (whoami) — #{e.message}"
      end

      # An unjoined room syncs as empty, which looks the same as a quiet one.
      def ensure_joined!
        joined = @client.joined_rooms
        return if joined.include?(@ctx.matrix_room_id)
        raise OPilot::FatalError, "#{@bot_id} has not joined #{@ctx.matrix_room_id} — invite the bot " \
                                  "and join once by hand, and check MATRIX_ROOM_ID (the !id, not an alias). " \
                                  "Joined: #{joined.empty? ? "none" : joined.join(", ")}"
      rescue Clients::Matrix::Error => e
        raise OPilot::FatalError, "could not list the Matrix rooms opilot has joined — #{e.message}"
      end

      def state_file
        base_dir / "sync.json"
      end

      # One LLM session per Matrix thread, keyed by its root event.
      def session_file(thread_root)
        dir = base_dir / "sessions"
        dir.mkpath
        dir / thread_root.to_s.gsub(/[^A-Za-z0-9_-]/, "_")
      end

      # The first sync only stores the token, so history is never answered.
      def poll_intents
        ensure_bot_identity! unless @bot_id
        first = state["next_batch"].nil?
        res = @client.sync(since: state["next_batch"], filter: filter)
        @pending_batch = res["next_batch"]
        timeline = first ? {} : res.dig("rooms", "join", @ctx.matrix_room_id, "timeline") || {}
        events = Array(timeline["events"])
        @event_count = events.length
        if first
          commit_batch
          log_script "Matrix: first sync — earlier messages in #{@ctx.matrix_room_id} are not answered."
        end
        log_script "Matrix: the room had more new messages than one sync returns; some are skipped." if timeline["limited"]
        events.filter_map { |e| intent_for(e) }
      end

      def mark_handled(event_id)
        state["handled"] = (state["handled"] + [event_id]).last(MAX_HANDLED)
        save_state
      end

      # Advance the sync token once the batch is handled. An idle tick writes nothing.
      def commit_batch
        return if @pending_batch.nil? || @pending_batch == state["next_batch"]
        state["next_batch"] = @pending_batch
        save_state
      end

      private

      def base_dir
        @ctx.state_dir / "matrix" / @ctx.matrix_host
      end

      def filter
        {
          "presence"     => { "types" => [] },
          "account_data" => { "types" => [] },
          "room" => {
            "rooms"        => [@ctx.matrix_room_id],
            "state"        => { "types" => [] },
            "ephemeral"    => { "types" => [] },
            "account_data" => { "types" => [] },
            "timeline"     => { "types" => ["m.room.message", "m.room.encrypted"], "limit" => 50 }
          }
        }
      end

      def intent_for(event)
        id = event["event_id"]
        return nil if id.nil? || state["handled"].include?(id)
        return nil if event["sender"] == @bot_id
        return warn_encrypted if event["type"] == "m.room.encrypted"

        content = event["content"] || {}
        # m.notice is the bot message type: answering one can start a bot loop.
        return nil unless content["msgtype"] == "m.text"
        return nil if content.dig("m.relates_to", "rel_type") == "m.replace" # an edit

        text = addressed_text(content)
        return nil unless text

        unless @ctx.allowed_matrix_users.include?(event["sender"])
          log_script "Matrix: ignored a message from #{event["sender"]} (not in OPILOT_ALLOWED_MATRIX_USERS)"
          return nil
        end

        relates = content["m.relates_to"] || {}
        root = relates["rel_type"] == "m.thread" ? relates["event_id"] : id
        Intent.new(event_id: id, sender: event["sender"], thread_root: root, **parse(text))
      end

      def warn_encrypted
        unless @warned_encrypted
          log_script "Matrix: room #{@ctx.matrix_room_id} is encrypted — opilot cannot read it. Use an unencrypted room."
          @warned_encrypted = true
        end
        nil
      end

      # The message without the leading mention, or nil when it is not for opilot.
      # A reply to opilot's own message carries the mention in `m.mentions` only.
      def addressed_text(content)
        body = strip_reply_fallback(content["body"].to_s)
        return body.sub(@prefix, "").strip if body.match?(@prefix)
        Array(content.dig("m.mentions", "user_ids")).include?(@bot_id) ? body.strip : nil
      end

      # Older clients quote the replied-to message as leading "> " lines.
      def strip_reply_fallback(body)
        lines = body.lines
        return body unless lines.first&.start_with?(">")
        lines.drop_while { |l| l.start_with?(">") }.join.lstrip
      end

      # The OpenProject command words (CommandWords), each with its work package
      # first, because a room has none of its own. Never passed to the CLI: room
      # members must not reach `reset` or `op wp create` this way. Anything else
      # is chat, as in an OpenProject comment; its `ids` are the work packages it names.
      def parse(text)
        return { verb: :unknown, ids: [] } if text.strip.empty?
        cmd = CommandWords.match(text)
        return { verb: :chat, ids: wp_refs(text), message: text } unless cmd

        words = cmd[:rest].split
        ids = words.map { |w| wp_id(w) }.take_while(&:itself)
        max = cmd[:verb] == :health ? MAX_IDS : 1
        problem = if ids.empty? then "`#{cmd[:word]}` needs a work-package id first, e.g. `@opilot #{cmd[:word]} #1323`."
                  elsif max > 1 && ids.length > max then "I check at most #{max} work packages per message."
                  end
        return { verb: :unknown, ids: [], problem: problem } if problem

        ids = ids.first(max)
        rest = cmd[:rest].sub(/\A(?:\S+\s*){#{ids.length}}/, "")
        return { verb: cmd[:verb], ids: ids, message: rest } unless cmd[:verb] == :lens
        { verb: :chat, ids: ids,
          message: "#{Prompts::Advisor.lens(cmd[:word], rest)}\n\nThis is about work package #{Helpers.wp_label(ids.first)}." }
      end

      # A word as a work-package id ("#1323", "proj-7,"), or nil.
      def wp_id(word)
        id = Helpers.wp_id_arg(word.delete_suffix(","))
        id if id.match?(WP_ID_PATTERN)
      end

      # "#1323" and "PROJ-7" — a bare number is too often something else.
      def wp_refs(text)
        text.scan(/(?<![\w#])#(\d+)\b|\b([A-Z][A-Z0-9_]*-\d+)\b/).map(&:compact).flatten.uniq.first(MAX_IDS)
      end

      # sync.json, read once and kept in memory.
      def state
        @state ||= begin
          saved = Helpers.safe_json_read(state_file) || {}
          { "next_batch" => saved["next_batch"], "handled" => Array(saved["handled"]) }
        end
      end

      def save_state
        state_file.dirname.mkpath
        Helpers.write_json_atomic(state_file, state, "matrix-sync")
      end
    end
  end
end
