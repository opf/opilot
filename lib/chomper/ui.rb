require "json"
require "rainbow"

module Chomper
  class UI
    def initialize(ctx)
      @ctx = ctx
    end

    def status
      items_dir = @ctx.state_dir / "items"
      unless items_dir.exist? && items_dir.children.any?
        puts "No work packages seen yet. Run ./chomper agent and mention @chomper on a WP."
        return
      end

      rows = items_dir.children.select(&:directory?).sort.map do |dir|
        id   = dir.basename.to_s
        item = (JSON.parse((dir / "item.json").read) rescue {})
        pr   = dir / "pr_url.txt"
        {
          id:      id,
          subject: item["subject"] || "(unknown)",
          url:     item["url"],
          planned: (dir / "plan.md").exist?,
          pr_url:  pr.exist? ? pr.read.strip : nil
        }
      end

      shipped = rows.count { |r| r[:pr_url] }
      planned = rows.count { |r| r[:planned] && !r[:pr_url] }
      puts ""
      puts "  #{rows.length} watched  ✎ #{planned} planned  ✓ #{shipped} shipped"
      puts ""
      rows.each do |r|
        flag = r[:pr_url] ? "✓" : (r[:planned] ? "✎" : "·")
        puts "    #{flag} #{Rainbow("##{r[:id].ljust(6)}").bold}  #{Rainbow(r[:subject]).bold}"
        puts "               #{r[:url]}"      if r[:url]
        puts "               PR: #{r[:pr_url]}" if r[:pr_url]
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

        Usage: ./chomper [COMMAND]

        Commands:
          agent     Poll OpenProject every 10s and act on @chomper mentions
          status    Show watched work packages (planned / shipped) and recent progress
          reset     De-register the worktree and delete .chomper/ (fresh start)

        Options:
          --help, -h    Show this help

        @chomper comment commands (on any watched work package):
          @chomper <text>          Ask a question — replies with the plan as context
          @chomper plan [feedback] Generate (or revise) an implementation plan
          @chomper approve         Implement the plan and open a draft PR
          @chomper fix [feedback]  Plan and ship in one step, skipping approval

        Environment:
          OPENPROJECT_URL         OpenProject instance URL
          OPENPROJECT_TOKEN       OpenProject API token
          ANTHROPIC_API_KEY       Passed into the claude container if set
          GITHUB_TOKEN            Required for pushing branches and opening PRs
          CHOMPER_ALLOWED_EMAILS  Comma-separated allowlist of @chomper triggerers

        State (all in .chomper/, gitignored):
          agent_filters.json  Saved search filters (created on first agent run)
          items/<id>/         Per-WP folder: item.json, plan.md, pr.md, pr_url.txt
          openproject/        Isolated git worktree for fixes
          progress.txt        Progress log
          claude-auth/        Persisted claude container auth (delete to re-authenticate)
          chomp.log           Full prompt + response log

      USAGE
    end
  end
end
