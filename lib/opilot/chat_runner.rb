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
      loop do
        if pending.empty?
          print "\n  You (empty line to exit): "
          pending = $stdin.gets&.chomp.to_s
        end
        break if pending.empty?

        wp_root = container_path(Helpers.items_dir(@ctx))   # /state/work_packages/<host>
        prompt  = Prompts.free_chat(state: @ctx.state_container, wp_root: wp_root, repos: repos, message: pending,
                                    op_mcp: @ctx.op_mcp?, gh_mcp: @ctx.gh_mcp?)
        @harness.run(prompt, tools: read_tools, session_file: session_file)
        ping_terminal("opilot: chat reply ready")
        puts ""
        pending = ""
      end
    end
  end
end
