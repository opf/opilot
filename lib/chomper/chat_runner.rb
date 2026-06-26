module Chomper
  # The `chat` command: a free, read-only terminal conversation over chomper's
  # local mirrors. Unlike the op-agent chat (posted to OpenProject) or the
  # fix/plan `[c]hat` (scoped to one WP's plan), it isn't tied to any work
  # package — the whole .chomper cache is mounted read-only at /state and Claude
  # finds the relevant files itself from the question. No fetch, no plan, no
  # ship: just talk. Mirrors FixRunner#run_chat's REPL shape.
  class ChatRunner
    include Helpers

    def initialize(ctx, claude: Claude.new(ctx))
      @ctx    = ctx
      @claude = claude
    end

    # Drive the REPL. `initial_message` (the inline text after `./chomper chat`)
    # is sent as the first turn when present; otherwise the loop prompts for it.
    def run(initial_message = nil)
      # One fresh session per invocation: thread context across turns within this
      # run, but never resume a stale conversation from a previous one.
      session_file = @ctx.state_dir / "chat_session_id"
      safe_rm(session_file)

      repos = repos_for_prompt(@ctx.repos.all)
      puts "  Free chat — read-only over your local mirrors (/state) and the repo clones (/repos)."
      puts "  Empty line to exit."

      pending = initial_message.to_s.strip
      loop do
        break if Chomper.stopping?
        if pending.empty?
          print "\n  You (empty line to exit): "
          pending = $stdin.gets&.chomp.to_s
        end
        break if pending.empty?

        prompt = Prompts.free_chat(state: @ctx.state_container, repos: repos, message: pending)
        @claude.run(prompt, tools: Claude::TOOLS_READ, session_file: session_file)
        ping_terminal("chomper: chat reply ready")
        puts ""
        pending = ""
      end
    end
  end
end
