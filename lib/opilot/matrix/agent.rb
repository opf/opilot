module OPilot
  module Matrix
    # The Matrix chat interface: the OpenProject command words in one room, each
    # naming its work package first (Matrix::Pull#parse). `build` and `create wp`
    # run OpenProject::Agent's own handlers, their notes sent here. Other text is
    # chat, like `./opilot chat`, one session per thread. Replies go in the thread.
    class Agent
      include Helpers

      # Matrix refuses events over 64 KiB, and the body is only part of one.
      MAX_BODY_BYTES = 60_000
      HELP = "Ask me a question, or name a work package after a command: `health #1323`, " \
             "`grill #1323`, `summarize #1323`, `build #1323`, `create wp #1323 <what>`.".freeze

      # `op_agent:` is shared with CombinedAgent, so its Pull (and the identity
      # it caches) is too.
      def initialize(ctx, pull: Matrix::Pull.new(ctx), harness: Harness.new(ctx), op_agent: nil,
                     op_pull: nil, health: nil)
        @ctx      = ctx
        @pull     = pull
        @harness  = harness
        @op_pull  = op_pull || op_agent&.pull || OpenProject::Pull.new(ctx)
        @op_agent = op_agent || OpenProject::Agent.new(ctx, pull: @op_pull, harness: harness)
        @health   = health || OpenProject::HealthCheck.new(ctx, pull: @op_pull, harness: harness)
      end

      def run
        ensure_harness!
        setup
        puts "  Matrix agent started — polling every #{POLL_INTERVAL}s. Ctrl-C to stop."
        loop do
          guarded_tick("Matrix poll") { tick }
          sleep POLL_INTERVAL
        end
      end

      # Refuses without an allowlist: a Matrix user is not an OpenProject user,
      # yet would reach everything OPENPROJECT_TOKEN can read.
      def setup
        unless @ctx.matrix?
          raise OPilot::FatalError, "Matrix is not configured — set MATRIX_HOMESERVER_URL, " \
                                    "MATRIX_ACCESS_TOKEN and MATRIX_ROOM_ID in .env."
        end
        if @ctx.allowed_matrix_users.empty?
          raise OPilot::FatalError, "OPILOT_ALLOWED_MATRIX_USERS is empty — the Matrix interface needs an " \
                                    "allowlist of Matrix user ids (e.g. @you:example.org)."
        end
        @pull.ensure_bot_identity!
        @pull.ensure_joined!
        # The health check tells opilot's own comments apart by this identity.
        @op_pull.ensure_bot_identity!
        report_mcp_status
        puts "  Matrix: #{@pull.bot_id} answers in #{room}, only for: #{@ctx.allowed_matrix_users.join(", ")}"
        nil
      end

      def tick
        intents = @pull.poll_intents
        n = intents.length
        log_script "Polled Matrix (#{room}) — #{@pull.event_count} message(s), " \
                   "#{n} @opilot trigger#{n == 1 ? "" : "s"}"
        intents.each { |intent| handle_and_ack(intent) }
        @pull.commit_batch
      end

      # As OpenProject::Agent#handle_and_ack: a handled error is still acked, a
      # Ctrl-C is not. Unlike there, the error is answered: the reader would wait.
      def handle_and_ack(intent)
        handle(intent)
        @pull.mark_handled(intent.event_id)
      rescue StandardError, ScriptError => e
        stop_on_code_error!(e)
        log_script "Matrix error on #{intent.event_id} (#{intent.verb}): #{e.class}: #{e.message}"
        reply(intent, "I could not finish this. #{PING_MAINTAINER}", part: "error") rescue nil
        @pull.mark_handled(intent.event_id)
      end

      def handle(intent)
        log_script "Matrix — #{intent.sender} — #{intent.verb} — #{intent.message}"
        return reply(intent, [intent.problem, HELP].compact.join(" "), part: 0) if intent.verb == :unknown

        client.react(room, intent.event_id, "👀", txn_id: "opilot-#{intent.event_id}-eyes")
        typing do
          case intent.verb
          when :health
            intent.ids.each_with_index { |id, i| reply(intent, health_report(intent, id), part: i) }
          when :chat then reply(intent, chat_answer(intent), part: 0)
          when :ship, :create_wp then on_work_package(intent)
          end
        end
      end

      private

      def room
        @ctx.matrix_room_id
      end

      def typing
        client.typing(room, @pull.bot_id)
        yield
      ensure
        client.typing(room, @pull.bot_id, typing: false)
      end

      def unreadable(id)
        "I could not read work package #{wp_label(id)}. Check the id."
      end

      # `internal: false`: room members are not an OpenProject audience, so
      # findings that cite an internal comment stay out of the reply.
      def health_report(intent, id)
        report = @health.run(id, focus: intent.message.to_s, internal: false)
        report ? "#{wp_label(id)}\n\n#{report}" : unreadable(id)
      rescue Harness::Error => e
        log_script "Health check failed on #{wp_label(id)}: #{e.message}"
        "The health check of #{wp_label(id)} did not finish: the model run failed. Ask again."
      end

      # `build` and `create wp` on a fresh copy of the work package; each note the
      # handler would comment becomes a reply. The event id keeps `create wp` idempotent.
      def on_work_package(intent)
        # Checked here: CreateWp says "off" once per work package, so a second ask would get only 👀.
        if intent.verb == :create_wp && !OpenProject::CreateWp.enabled?(@ctx)
          return reply(intent, OpenProject::CreateWp::DISABLED_NOTE, part: 0)
        end
        id = intent.ids.first
        item = @op_pull.fetch_single_item(id)
        return reply(intent, unreadable(id), part: 0) unless item

        op_intent = OpenProject::Intent.new(item_id: item["id"], subject: item["subject"], type: item["type"].to_s,
                                            command: intent.verb, text: intent.message.to_s,
                                            comment_at: "matrix:#{intent.event_id}", internal: true)
        notes = 0
        @op_agent.handle_elsewhere(op_intent, build_ref: wp_label(item["id"]),
                                   reply: ->(_item_id, msg) { reply(intent, msg, part: notes += 1) })
      end

      # Free chat over the mirrors. The first turn of a thread orients the model
      # and syncs the clones; later turns resume the thread's session.
      def chat_answer(intent)
        fetched = fetch_named(intent.ids)
        session = @pull.session_file(intent.thread_root)
        prompt = if Helpers.file_has_content?(session)
                   Prompts::Advisor.room_follow_up(message: intent.message, sender: intent.sender, fetched: fetched)
                 else
                   sync_bases_for_reading(@ctx.repos.all)
                   Prompts::Advisor.room_chat(state: @ctx.state_container, wp_root: container_path(Helpers.items_dir(@ctx)),
                                              repos: repos_for_prompt(@ctx.repos.all), message: intent.message,
                                              sender: intent.sender, fetched: fetched,
                                              op_mcp: op_mcp_live?, gh_mcp: @ctx.gh_mcp?)
                 end
        answer = llm(:advisor, prompt, session_file: session).to_s.strip
        answer.empty? ? "I have no answer to this. Ask again in other words." : answer
      rescue Harness::Error => e
        log_script "Matrix chat failed: #{e.message}"
        "The chat did not finish: the model run failed. Ask again."
      end

      # Refresh the work packages a chat names, so it reads them current — chat
      # otherwise sees only what an earlier run mirrored. Container paths.
      def fetch_named(ids)
        ids.filter_map do |id|
          item = @op_pull.fetch_single_item(id)
          container_path(Helpers.item_dir(@ctx, item["id"]) / "item.json") if item
        rescue StandardError => e
          log_script "Matrix chat: could not fetch #{wp_label(id)} (#{e.class}: #{e.message})"
          nil
        end
      end

      # The txn id comes from the trigger, so a replayed trigger is one message.
      def reply(intent, body, part:)
        client.send_notice(room, capped(body), txn_id: "opilot-#{intent.event_id}-#{part}",
                           reply_to: intent.event_id, thread_root: intent.thread_root, mention: intent.sender)
        log_script "Matrix reply posted in #{room}"
      end

      def capped(body)
        return body if body.bytesize <= MAX_BODY_BYTES
        "#{body.byteslice(0, MAX_BODY_BYTES).scrub("")}\n\n[The report is too long for one Matrix message. It stops here.]"
      end

      def client
        @pull.client
      end
    end
  end
end
