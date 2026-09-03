module OPilot
  # The `chat` command: a free, read-only terminal conversation over opilot's
  # local mirrors. Unlike the op-agent chat (posted to OpenProject) or the
  # fix/plan `[c]hat` (scoped to one WP's plan), it isn't tied to any work
  # package — the whole .opilot cache is mounted read-only at /state and the LLM
  # finds the relevant files itself from the question. No fetch, no plan, no
  # ship: just talk. Mirrors FixRunner#run_chat's REPL shape.
  class ChatRunner
    include Helpers

    def initialize(ctx, harness: Harness.new(ctx))
      @ctx    = ctx
      @harness = harness
    end

    # Drive the REPL. `initial_message` (the inline text after `./opilot chat`)
    # is sent as the first turn when present; otherwise the loop prompts for it.
    def run(initial_message = nil)
      # One fresh session per invocation: thread context across turns within this
      # run, but never resume a stale conversation from a previous one.
      ensure_harness!
      report_mcp_status
      session_file = @ctx.state_dir / "chat_session_id"
      safe_rm(session_file)

      repos = repos_for_prompt(@ctx.repos.all)
      # Once per run, not per turn: a question about the code should be answered
      # against current upstream rather than whatever branch the last ship or
      # `pd` run left the clone on.
      sync_bases_for_reading(@ctx.repos.all)
      puts "  Free chat — read-only over your local mirrors (/state) and the repo clones (/repos)."
      puts "  Empty line to exit."

      pending = initial_message.to_s.strip
      # The orientation — where the mirrors are, which repos exist, how to
      # reply — is worth ~1000 tokens and is sent ONCE. Every later turn resumes
      # the same pi session, which still holds it, so a follow-up is just the
      # user's message. Re-sending it per turn was pure duplication, growing the
      # context by that much on every question.
      #
      # A local flag rather than `session_file.exist?`, because the two are not
      # the same test everywhere: FixRunner#run_chat enters its loop with a
      # session that already exists (the planning run made it) but has never
      # seen the chat orientation. "Have I sent it in this loop" is the actual
      # question, and it is the same question in both.
      oriented = false
      loop do
        if pending.empty?
          print "\n  You (empty line to exit): "
          pending = $stdin.gets&.chomp.to_s
        end
        break if pending.empty?

        wp_root = container_path(Helpers.items_dir(@ctx))   # /state/work_packages/<host>
        prompt  = if oriented
                    pending
                  else
                    Prompts.free_chat(state: @ctx.state_container, wp_root: wp_root, repos: repos,
                                      message: pending, op_mcp: @ctx.op_mcp?, gh_mcp: @ctx.gh_mcp?)
                  end
        @harness.run(prompt, tools: read_tools, session_file: session_file)
        # Set only after the run returns: a failed turn never reached the model,
        # so the next one still has to orient it.
        oriented = true
        ping_terminal("opilot: chat reply ready")
        puts ""
        pending = ""
      end
    end
  end
end
