require "rainbow"

module Chomper
  class UI
    include Helpers

    def initialize(ctx, backlog)
      @ctx     = ctx
      @backlog = backlog
    end

    def status
      unless @backlog.exist?
        puts "No backlog yet. Run ./chomper to fetch and triage."
        return
      end

      done        = @backlog.committed.length
      in_progress = @backlog.in_progress.length
      pending     = @backlog.pending.length
      planned     = @backlog.planned.length
      blk         = @backlog.blocked.length
      untriaged   = @backlog.untriaged.length
      puts ""
      summary = "  #{pending} pending"
      summary += "  ▶ #{in_progress} in progress" if in_progress > 0
      summary += "  ✎ #{planned} planned"          if planned      > 0
      summary += "  ✓ #{done} done"                if done         > 0
      summary += "  ✗ #{blk} blocked"              if blk          > 0
      summary += "  ? #{untriaged} untriaged"       if untriaged    > 0
      puts summary

      { "In progress" => @backlog.in_progress, "Pending" => @backlog.pending,
        "Planned" => @backlog.planned, "Done" => @backlog.committed,
        "Blocked" => @backlog.blocked, "Untriaged" => @backlog.untriaged }.each do |label, list|
        next if list.empty?
        puts ""
        puts "  #{label}:"
        list.each do |item|
          id   = item["id"]
          lg   = item["locality_group"] || "?"
          cplx = item["complexity"]     || "?"
          puts "    #{Rainbow("##{id.ljust(6)}").bold}  #{Rainbow(item["subject"]).bold}  (#{lg} / #{cplx})"
          puts "               #{item["url"]}" if item["url"]

          item_dir  = @ctx.state_dir / "items" / id
          gist_file = item_dir / "gist.txt"
          pr_file   = item_dir / "pr_url.txt"

          if item_dir.exist?
            puts "               Branch: #{branch_slug(id, item["subject"])}"
          end
          puts "               Plan: #{gist_file.read.chomp}" if gist_file.exist?
          if pr_file.exist?
            puts "               PR:   #{pr_file.read.chomp}"
          elsif label == "Done"
            puts "               No PR yet — run: ./chomper publish #{id}"
          end
        end
      end

      if @ctx.progress_file.exist? && @ctx.progress_file.size > 0
        puts ""
        puts "  Recent:"
        @ctx.progress_file.readlines.last(5).each do |line|
          ts, id, _, note = line.chomp.split("|")
          puts "    #{ts}  ##{id}  #{note}"
        end
      end
      puts ""
    end

    def reset
      puts ""
      puts "This will de-register the worktree and delete .chomper/ entirely."
      print "  Confirm? [y/N] "
      yn = $stdin.gets.chomp
      unless yn.downcase.start_with?("y")
        puts "Aborted."
        puts ""
        return
      end

      if @ctx.repo_path
        wt = @ctx.worktree_host
        list = IO.popen(
          ["git", "-C", @ctx.repo_path.to_s, "worktree", "list"],
          err: IO::NULL, &:read
        )
        if list.include?(wt.to_s)
          puts "  De-registering worktree #{wt}..."
          system("git", "-C", @ctx.repo_path.to_s,
                 "worktree", "remove", "--force", wt.to_s, err: IO::NULL)
          system("git", "-C", @ctx.repo_path.to_s, "worktree", "prune", err: IO::NULL)
        end
      end

      puts "  Removing #{@ctx.state_dir}..."
      @ctx.state_dir.rmtree
      puts "  ✓ Reset complete."
      puts ""
    end

    def usage
      puts <<~USAGE

        Usage: ./chomper [COMMAND [IDs...]]

        Commands:
          fix [id id ...]     Fix all pending bugs, or only the specified ticket IDs
          plan [id id ...]    Generate plans only — no implementation
          publish [id id ...] Push branches and open draft PRs (all committed, or specific IDs)
          purge <id id ...>   Remove specific items from the queue
          agent               Poll OpenProject every 10s and sync updated work packages
          status              Show backlog counts and recent progress
          reset               De-register the worktree and delete .chomper/ (fresh start)

        Options:
          --help, -h    Show this help

        Environment:
          ANTHROPIC_API_KEY       Passed into the claude container if set
          GITHUB_TOKEN            Required for gist creation and opening PRs

        State (all in .chomper/, gitignored):
          config          OpenProject URL, token, project, repo path
          backlog.json        Fetched + triaged bugs
          agent_filters.json  Saved search filters for agent mode (created on first agent run)
          agent_emails.txt    Saved allowed emails for agent mode (created on first agent run)
          agent_filters.json  Saved search filters for agent mode
          items/<id>/     Per-WP folder: item.json, plan.md, review.txt, pr.md, gist.txt
          openproject/    Isolated git worktree for fixes
          progress.txt    Fix log
          claude-auth/    Persisted claude container auth (delete to re-authenticate)
          chomp.log       Full prompt + response log

      USAGE
    end

    private

    def log(msg)
      ts = Time.now.strftime("%H:%M:%S")
      puts Rainbow("[ #{ts} ] #{msg}").bold
    end
  end
end
