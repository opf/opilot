module Chomper
  # The terminal `pull` command: mirror OpenProject work packages into the local
  # cache so they can be discussed via `chat`, without planning or shipping.
  # With ids it fetches exactly those WPs; with none it runs the filter wizard
  # and mirrors every match (the same project scope op-agent uses).
  class PullRunner
    include Helpers

    def initialize(ctx, pull: Pull.new(ctx))
      @ctx  = ctx
      @pull = pull
    end

    def run(*wp_ids)
      wp_ids.empty? ? pull_by_filter : pull_by_ids(wp_ids)
    end

    private

    def pull_by_ids(wp_ids)
      ok = 0
      wp_ids.each do |wp_id|
        log_script "Fetching work package #{wp_label(wp_id)}…"
        item = @pull.fetch_single_item(wp_id)
        if item
          ok += 1
          puts "  #{wp_label(item["id"])} — #{item["subject"]}"
        else
          puts "  #{wp_label(wp_id)} — could not fetch (check the id and OPENPROJECT_TOKEN)"
        end
      end
      summary(ok, wp_ids.length)
    end

    def pull_by_filter
      filters = @pull.load_or_prompt_agent_filters
      scanned, changed = @pull.mirror(filters)
      puts ""
      puts "  Scanned #{scanned} work package(s); refreshed #{changed}."
      puts "  Discuss them with: ./chomper chat"
    end

    def summary(ok, total)
      puts ""
      puts "  Mirrored #{ok}/#{total} work package(s) into the local cache."
      puts "  Discuss them with: ./chomper chat"
    end
  end
end
