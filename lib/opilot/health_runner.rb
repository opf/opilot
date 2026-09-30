module OPilot
  # The terminal `dev health`: run HealthCheck on each id and print the report.
  # It posts nothing, so a prompt change can be tuned on a real work package.
  class HealthRunner
    include Helpers

    def initialize(ctx, pull: Pull.new(ctx), harness: Harness.new(ctx), api: nil)
      @ctx     = ctx
      @pull    = pull
      @harness = harness
      @check   = HealthCheck.new(ctx, pull: pull, harness: harness, api: api)
    end

    # One failure does not stop the rest; with a single id it is fatal.
    def run_ids(*wp_ids)
      ensure_harness!
      report_mcp_status
      wp_ids.each do |wp_id|
        log_script "Checking work package #{wp_label(wp_id)}…"
        report = @check.run(wp_id)
        unless report
          msg = "could not fetch work package #{wp_label(wp_id)} — check the id and OPENPROJECT_TOKEN"
          raise OPilot::FatalError, msg if wp_ids.length == 1
          log_script "#{wp_label(wp_id)} — #{msg}"
          next
        end
        puts ""
        puts render_markdown(report)
      rescue Harness::Error => e
        raise OPilot::FatalError, "The LLM run failed: #{e.message}" if wp_ids.length == 1
        log_script "#{wp_label(wp_id)} — The LLM run failed: #{e.message}"
      end
    end
  end
end
