require "rainbow"

module Chomper
  class CLI
    include Helpers

    def initialize(ctx)
      @ctx = ctx
    end

    def run(argv)
      cmd  = argv[0] || ""
      ids  = argv[1..]

      backlog = Backlog.new(@ctx.backlog_json)
      ui      = UI.new(@ctx, backlog)

      case cmd
      when "", "--help", "-h"
        ui.usage
        return
      when "status"
        ui.status
        return
      when "reset"
        ui.reset
        return
      when "publish"
        @ctx.load_config!
        Publish.new(@ctx, backlog).run_publish_stage(ids)
        return
      when "purge"
        if ids.empty?
          $stderr.puts "purge requires at least one ID. To wipe everything, use: ./chomper reset"
          raise Chomper::FatalError
        end
        backlog.remove_items(ids)
        puts "Purged #{ids.length} item(s) from the queue."
        return
      when "fix", "plan"
        # handled below
      else
        $stderr.puts "Unknown argument: #{cmd}"
        ui.usage
        raise Chomper::FatalError
      end

      @ctx.log_file.open("a") { |f| f.puts "\n=== Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }

      @ctx.load_config!

      claude = Claude.new(@ctx)

      if ids.any?
        log_script "Stage 1: FETCH — loading WPs #{ids.join(" ")}"
        Pull.new(@ctx, backlog).run_fetch_ids_stage(ids)
        log_script "Stage 1 complete: #{ids.length} WPs loaded"
      else
        log_script "Stage 1: PULL — fetching backlog from #{@ctx.op_url}"
        Pull.new(@ctx, backlog).run_pull_stage
        log_script "Stage 1 complete: #{backlog.items.length} bugs in backlog"
      end

      unless ids.any?
        log_script "Stage 2: TRIAGE"
        Triage.new(@ctx, backlog, claude).run_triage_stage
        log_script "Stage 2 complete: #{backlog.pending.length} issues triaged"
      end

      pending = backlog.pending + backlog.planned
      if pending.empty?
        puts "=== Nothing left to do. All issues resolved. ==="
        return
      end

      log_script "Stage 3: #{cmd.upcase} — #{pending.length} pending items"
      fix = Fix.new(@ctx, backlog, claude)
      pending.each do |item|
        item_id = item["id"]
        log_script "Item ##{item_id} — start  (#{@ctx.state_dir}/items/#{item_id})"
        fix.fix_item(item_id, cmd)
      rescue => e
        log_script "ERROR on ##{item_id}: #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
        log_script "Item ##{item_id} — end  (#{@ctx.state_dir}/items/#{item_id})"
      end
      log_script "Stage 3 complete"

      if cmd == "plan"
        puts "=== Plan complete — plans in .chomper/items/<id>/plan.md ==="
        puts "Run ./chomper fix [ids...] to implement."
      else
        puts "=== Session complete ==="
        puts "Push when ready."
      end
    end
  end
end
