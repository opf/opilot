require_relative "agent"
require_relative "gh_agent"

module Chomper
  # The `agent` command: run the OpenProject loop (Agent) and the GitHub-PR loop
  # (GhAgent) together in one single-threaded process. Each tick polls GitHub
  # first, then OpenProject, handling intents one at a time.
  #
  # Single-threaded on purpose: both loops drive the *same* repo clones
  # (.chomper/repos/<name>), so their work must be serialized anyway — running
  # them in parallel would just need a lock around every checkout. Interleaving
  # one tick of each per cycle gives "watch both sources from one command"
  # without the concurrency hazards.
  #
  # When GITHUB_TOKEN is unset the GitHub side is skipped and this degrades to an
  # OpenProject-only loop (same as `op-agent`), rather than erroring out.
  class CombinedAgent
    include Helpers

    def initialize(ctx, agent: Agent.new(ctx), gh_agent: GhAgent.new(ctx))
      @ctx      = ctx
      @agent    = agent
      @gh_agent = gh_agent
    end

    def run
      gh_enabled = !@ctx.github_token.nil?
      unless gh_enabled
        puts "  GITHUB_TOKEN not set — running OpenProject only (no PR watching)."
      end

      # GitHub first, so its scan-window prompt and OpenProject's filter prompt
      # are both resolved before the loop starts.
      scan_from_at = @gh_agent.setup if gh_enabled
      filters      = @agent.setup
      puts "  Agent started — polling chomper PRs + OpenProject every #{POLL_INTERVAL}s. Ctrl-C to stop."

      until Chomper.stopping?
        guarded_tick("PR poll") { @gh_agent.tick(scan_from_at) } if gh_enabled
        break if Chomper.stopping?
        guarded_tick("OpenProject poll") { @agent.tick(filters) }
        sleep POLL_INTERVAL unless Chomper.stopping?
      end
      puts "  Stopped."
    end
  end
end
