require "rainbow"

module OPilot
  # `./opilot dev status` — the work packages opilot has acted on. Reads
  # .opilot/ only: no config, no network, no log header.
  class StatusRunner
    def initialize(ctx)
      @ctx = ctx
    end

    def run
      items_dir = Helpers.items_dir(@ctx)
      dirs = items_dir.exist? ? items_dir.children.select(&:directory?).sort : []

      rows = dirs.filter_map do |dir|
        # Per-repo PR urls live under <id>/repos/<name>/pr_url.txt — a WP may
        # have shipped to several repos.
        pr_files = (dir / "repos").exist? ? (dir / "repos").children.map { |d| d / "pr_url.txt" }.select(&:exist?) : []
        # Only work packages opilot has acted on — not every polled (cached) WP.
        # options.json counts: opilot answered with implementation options and is
        # waiting for a number, which is action taken and work still open.
        next unless (dir / "plan.md").exist? || (dir / "options.json").exist? || pr_files.any?
        item = Helpers.safe_json_read(dir / "item.json") || {}
        {
          id:       dir.basename.to_s,
          subject:  item["subject"] || "(unknown)",
          url:      item["url"],
          pr_urls:  pr_files.map { |f| f.read.strip },
          awaiting: !(dir / "plan.md").exist? && pr_files.empty? && (dir / "options.json").exist?
        }
      end

      if rows.empty?
        puts "Nothing yet. Run ./opilot agent and mention @opilot on a work package."
        return
      end

      shipped  = rows.count { |r| r[:pr_urls].any? }
      awaiting = rows.count { |r| r[:awaiting] }
      planned  = rows.length - shipped - awaiting
      puts ""
      puts "  📝 #{planned} planned   ⏳ #{awaiting} awaiting a choice   🚀 #{shipped} shipped"
      puts ""
      rows.each do |r|
        flag = if r[:pr_urls].any? then "🚀" elsif r[:awaiting] then "⏳" else "📝" end
        puts "    #{flag} #{Rainbow(Helpers.wp_label(r[:id]).ljust(7)).bold}  #{Rainbow(r[:subject]).bold}"
        puts "               #{r[:url]}" if r[:url]
        r[:pr_urls].each { |u| puts "               PR: #{u}" }
      end
      puts ""
    end
  end
end
