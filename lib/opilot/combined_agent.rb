module OPilot
  # The `agent` command: the OpenProject loop (OpenProject::Agent), the GitHub-PR loop
  # (GitHub::Agent) and, when configured, the Matrix room (Matrix::Agent) in one
  # single-threaded process, each tick polling GitHub, OpenProject, then Matrix,
  # one intent at a time.
  #
  # Single-threaded on purpose: both loops drive the *same* clones, so their work
  # has to be serialized anyway — parallelism would only add a lock around every
  # checkout. Without GITHUB_CONTRIBUTOR_TOKEN the GitHub side is skipped and this
  # degrades to an OpenProject-only loop rather than erroring out.
  class CombinedAgent
    include Helpers

    def initialize(ctx, agent: OpenProject::Agent.new(ctx), gh_agent: GitHub::Agent.new(ctx), matrix_agent: nil)
      @ctx      = ctx
      @agent    = agent
      @gh_agent = gh_agent
      # Built only when configured: its client needs the Matrix settings.
      @matrix_agent = matrix_agent || (Matrix::Agent.new(ctx, op_agent: agent) if ctx.matrix?)
    end

    def run
      gh_enabled = !@ctx.contributor_token.nil?
      unless gh_enabled
        puts "  GITHUB_CONTRIBUTOR_TOKEN not set — running OpenProject only (no PR watching)."
      end

      puts "  Matrix not configured (MATRIX_HOMESERVER_URL, MATRIX_ACCESS_TOKEN, MATRIX_ROOM_ID) — skipping it." \
        unless @matrix_agent

      # GitHub first, so both scan-window prompts are resolved before the loop
      # starts.
      gh_scan_from_at = @gh_agent.setup if gh_enabled
      op_scan_from_at = @agent.setup
      @matrix_agent&.setup
      puts "  Agent started — polling #{sources(gh_enabled, @matrix_agent)} every #{POLL_INTERVAL}s. Ctrl-C to stop."

      loop do
        guarded_tick("PR poll") { @gh_agent.tick(gh_scan_from_at) } if gh_enabled
        guarded_tick("OpenProject poll") { @agent.tick(op_scan_from_at) }
        guarded_tick("Matrix poll") { @matrix_agent.tick } if @matrix_agent
        sleep POLL_INTERVAL
      end
    end

    private

    def sources(gh, matrix)
      [("opilot PRs" if gh), "OpenProject", ("Matrix" if matrix)].compact.join(" + ")
    end
  end
end
