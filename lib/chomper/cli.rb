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
      when "agent"
        @ctx.load_config!
        pull    = Pull.new(@ctx, backlog)
        claude  = Claude.new(@ctx)
        triage  = Triage.new(@ctx, backlog, claude)
        fix     = Fix.new(@ctx, backlog, claude)
        publish = Publish.new(@ctx, backlog)
        filters = pull.load_or_prompt_agent_filters
        @ctx.allowed_emails = pull.load_or_prompt_agent_emails if @ctx.allowlist_enabled && @ctx.allowed_emails.empty?
        puts "  Agent started — polling every 10s. Ctrl-C to stop."
        loop do
          pull.run_agent_poll(filters)

          requested = backlog.requested
          unless requested.empty?
            puts "\n  [@chomper] #{requested.length} item(s) requested — triaging..."
            triage.run_triage_for_requested
            requested.each do |item|
              puts "  [@chomper] Planning ##{item["id"]} — #{item["subject"]}..."
              fix.fix_item(item["id"], "plan", require_approval: false)

              gist_url = publish.upload_plan_gist(item["id"], item["subject"])
              if gist_url
                note_body = {
                  "comment"  => { "raw" => "Plan ready for review: #{gist_url}" },
                  "internal" => true
                }
                code, = HTTP.post_json(
                  "#{@ctx.op_url}/api/v3/work_packages/#{item["id"]}/activities",
                  note_body,
                  token: @ctx.token
                )
                puts "  [@chomper] " + (code == 201 ? "Internal note posted to WP ##{item["id"]}" : "Note failed (HTTP #{code})")
              end
            rescue => e
              puts "  [@chomper] Error on ##{item["id"]}: #{e.message}"
            end
          end

          refinement = backlog.refinement_requested
          unless refinement.empty?
            puts "\n  [@chomper] #{refinement.length} item(s) need re-planning with feedback..."
            refinement.each do |item|
              puts "  [@chomper] Re-planning ##{item["id"]} — #{item["subject"]}..."
              fix.fix_item(item["id"], "plan", require_approval: false)

              gist_url = publish.upload_plan_gist(item["id"], item["subject"])
              if gist_url
                note_body = {
                  "comment"  => { "raw" => "Revised plan ready for review: #{gist_url}" },
                  "internal" => true
                }
                code, = HTTP.post_json(
                  "#{@ctx.op_url}/api/v3/work_packages/#{item["id"]}/activities",
                  note_body,
                  token: @ctx.token
                )
                puts "  [@chomper] " + (code == 201 ? "Revised note posted to WP ##{item["id"]}" : "Note failed (HTTP #{code})")
              end
            rescue => e
              puts "  [@chomper] Error on ##{item["id"]}: #{e.message}"
            end
          end

          fix_approved = backlog.fix_approved
          unless fix_approved.empty?
            puts "\n  [@chomper] #{fix_approved.length} item(s) approved — implementing..."
            fix_approved.each do |item|
              puts "  [@chomper] Implementing ##{item["id"]} — #{item["subject"]}..."
              fix.fix_item(item["id"], "fix", require_approval: false)
              publish.run_publish_stage([item["id"]])

              branch      = branch_slug(item["id"], item["subject"])
              pr_url_file = @ctx.state_dir / "items" / item["id"] / "pr_url.txt"
              pr_url      = pr_url_file.exist? ? pr_url_file.read.strip : nil
              note_text   = "Implementation complete. Branch: `#{branch}`"
              note_text  += " | PR: #{pr_url}" if pr_url

              code, = HTTP.post_json(
                "#{@ctx.op_url}/api/v3/work_packages/#{item["id"]}/activities",
                { "comment" => { "raw" => note_text }, "internal" => true },
                token: @ctx.token
              )
              puts "  [@chomper] " + (code == 201 ? "Note posted to WP ##{item["id"]}" : "Note failed (HTTP #{code})")
            rescue => e
              puts "  [@chomper] Error on ##{item["id"]}: #{e.message}"
            end
          end

          backlog.items.each do |item|
            chat_file = @ctx.state_dir / "items" / item["id"] / "chat_message.txt"
            next unless chat_file.exist?

            message = chat_file.read.strip
            chat_file.delete

            puts "  [@chomper] Chat on ##{item["id"]} — #{item["subject"][0, 50]}: #{message[0, 60]}"

            plan_file = @ctx.state_dir / "items" / item["id"] / "plan.md"
            plan_text = plan_file.exist? ? plan_file.read : "(no plan yet)"

            prompt = <<~PROMPT
              You are chomper, an AI code assistant working on OpenProject work package ##{item["id"]}: #{item["subject"]}

              CURRENT PLAN:
              #{plan_text}

              AVAILABLE COMMANDS (mention these when relevant):
              - @chomper plan       — generate an implementation plan
              - @chomper revise ... — revise the plan with feedback
              - @chomper proceed    — approve the plan and trigger implementation

              USER: #{message}

              Reply helpfully and concisely. Your response will be posted as an internal note.
            PROMPT

            response = claude.run(prompt, tools: Claude::TOOLS_READ)
            next if response.strip.empty?

            code, = HTTP.post_json(
              "#{@ctx.op_url}/api/v3/work_packages/#{item["id"]}/activities",
              { "comment" => { "raw" => response.strip }, "internal" => true },
              token: @ctx.token
            )
            puts "  [@chomper] " + (code == 201 ? "Chat reply posted to WP ##{item["id"]}" : "Reply failed (HTTP #{code})")
          rescue => e
            puts "  [@chomper] Chat error on ##{item["id"]}: #{e.message}"
          end

          sleep 10
        end
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

      backlog.reset_in_progress!
      pending = backlog.pending + backlog.planned
      pending = pending.select { |item| ids.map(&:to_s).include?(item["id"]) } if ids.any?
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
        planned = backlog.planned
        if planned.any?
          puts "=== #{planned.length} plan(s) saved — .chomper/items/<id>/plan.md ==="
          puts "Run ./chomper fix [ids...] to implement."
        else
          puts "=== No plans saved. ==="
        end
      else
        committed = backlog.committed
        puts committed.any? ? "=== Session complete — push when ready. ===" : "=== Nothing committed. ==="
      end
    end
  end
end
