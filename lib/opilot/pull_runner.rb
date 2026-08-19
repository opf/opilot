module OPilot
  # The terminal `pull` command: mirror the given OpenProject work packages
  # into the local cache so they can be discussed via `chat`, without
  # planning or shipping.
  class PullRunner
    include Helpers

    def initialize(ctx, pull: Pull.new(ctx))
      @ctx  = ctx
      @pull = pull
    end

    def run(*wp_ids)
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

    private

    def summary(ok, total)
      puts ""
      puts "  Mirrored #{ok}/#{total} work package(s) into the local cache."
      puts "  Discuss them with: ./opilot chat"
    end
  end
end
