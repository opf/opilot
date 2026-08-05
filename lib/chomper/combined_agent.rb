require_relative "agent"
require_relative "gh_agent"

module Chomper
  # The `agent` command: the OpenProject loop (Agent) and the GitHub-PR loop
  # (GhAgent) in one single-threaded process, each tick polling GitHub then
  # OpenProject, one intent at a time.
  #
  # Single-threaded on purpose: both loops drive the *same* clones, so their work
  # has to be serialized anyway — parallelism would only add a lock around every
  # checkout. Without GITHUB_CONTRIBUTOR_TOKEN the GitHub side is skipped and this
  # degrades to an OpenProject-only loop rather than erroring out.
  class CombinedAgent
    include Helpers

    def initialize(ctx, agent: Agent.new(ctx), gh_agent: GhAgent.new(ctx))
      @ctx      = ctx
      @agent    = agent
      @gh_agent = gh_agent
    end

    def run
      gh_enabled = !@ctx.contributor_token.nil?
      unless gh_enabled
        puts "  GITHUB_CONTRIBUTOR_TOKEN not set — running OpenProject only (no PR watching)."
      end

      # GitHub first, so its scan-window prompt and OpenProject's filter prompt
      # are both resolved before the loop starts.
      scan_from_at = @gh_agent.setup if gh_enabled
      filters      = @agent.setup
      puts "  Agent started — polling chomper PRs + OpenProject every #{POLL_INTERVAL}s. Ctrl-C to stop."

      loop do
        guarded_tick("PR poll") { @gh_agent.tick(scan_from_at) } if gh_enabled
        guarded_tick("OpenProject poll") { @agent.tick(filters) }
        sleep POLL_INTERVAL
      end
    end
  end
end
