require "json"
require "rainbow"

module Chomper
  class UI
    def initialize(ctx)
      @ctx = ctx
    end

    def status
      items_dir = Helpers.items_dir(@ctx)
      dirs = items_dir.exist? ? items_dir.children.select(&:directory?).sort : []

      rows = dirs.filter_map do |dir|
        # Per-repo PR urls live under <id>/repos/<name>/pr_url.txt — a WP may
        # have shipped to several repos.
        pr_files = (dir / "repos").exist? ? (dir / "repos").children.map { |d| d / "pr_url.txt" }.select(&:exist?) : []
        # Only work packages chomper has acted on — not every polled (cached) WP.
        next unless (dir / "plan.md").exist? || (dir / "pr.md").exist? || pr_files.any?
        item = Helpers.safe_json_read(dir / "item.json") || {}
        {
          id:      dir.basename.to_s,
          subject: item["subject"] || "(unknown)",
          url:     item["url"],
          pr_urls: pr_files.map { |f| f.read.strip }
        }
      end

      if rows.empty?
        puts "Nothing yet. Run ./chomper op-agent and mention @chomper on a work package."
        return
      end

      shipped = rows.count { |r| r[:pr_urls].any? }
      planned = rows.length - shipped
      puts ""
      puts "  📝 #{planned} planned   🚀 #{shipped} shipped"
      puts ""
      rows.each do |r|
        flag = r[:pr_urls].any? ? "🚀" : "📝"
        puts "    #{flag} #{Rainbow(Helpers.wp_label(r[:id]).ljust(7)).bold}  #{Rainbow(r[:subject]).bold}"
        puts "               #{r[:url]}" if r[:url]
        r[:pr_urls].each { |u| puts "               PR: #{u}" }
      end
      puts ""
    end

    def reset
      puts ""
      puts "This will delete .chomper/ entirely (each repo is a standalone clone,"
      puts "so nothing outside .chomper/ is touched)."
      print "  Confirm? [y/N] "
      yn = $stdin.gets.chomp
      unless yn.downcase.start_with?("y")
        puts "Aborted."
        puts ""
        return
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
          agent     Run op-agent and gh-agent together (one loop: PRs first, then WPs)
          op-agent  Poll OpenProject every 20s and act on @chomper mentions
          gh-agent  Poll chomper's PRs every 20s; reply to @chomper comments and
                    (if asked) write code, committing it and pushing to the bot's fork
          plan <id>...      Plan one or more work packages with approval, but stop before building
          build <id>...     Plan, approve, and implement one or more work packages, committing the
                            fix to the local clone — nothing is pushed and no PR is opened
          ship <id>...      Plan, approve, implement, and ship one or more work packages as draft
                            PRs; picks up a branch committed earlier by build (`fix` is an alias).
                            Publishes via the contributor bot's fork; with GITHUB_MAINTAINER_TOKEN
                            set, publishes directly as the maintainer (each push confirmed)
          pr <id|url>...    Refresh a work package's shipped PR(s): merge in the latest base branch,
                            fix failing CI, and address new review comments, then push (with confirmation).
                            A pasted GitHub PR URL is resolved to its WP (and the WP mirrored) via the
                            OpenProject ticket link at the top of the PR description
          pull [<id>...]    Mirror work packages into the local cache for later chat (no plan or ship);
                            ids fetch exactly those, no ids runs the filter wizard for a bulk grab
          chat [message]    Free read-only chat about your local mirrors (items + PRs); no fetch or ship
          status    Show the work packages chomper has planned or shipped
          reset     De-register the worktree and delete .chomper/ (fresh start)

        Options:
          --help, -h    Show this help

        @chomper comment commands (on any watched work package):
          @chomper <text>          Ask a question — replies with the plan as context
          @chomper plan [feedback] Generate (or revise) an implementation plan
          @chomper approve         Implement the plan and open a draft PR
          @chomper ship [feedback] Plan and ship in one step, skipping approval (`fix` is an alias)
          @chomper grill [focus]   Stress-test the ticket/plan: gaps, edge cases, risks
          @chomper summarize [focus] Recap the thread: state, decisions, open questions

        @chomper PR comments (gh-agent, on a chomper-opened PR):
          @chomper <text>          Reply to the comment; if it asks for a code change,
                                   chomper writes it, commits, and pushes to the bot's fork

        Environment:
          OPENPROJECT_URL         OpenProject instance URL
          OPENPROJECT_TOKEN       OpenProject API token
          ANTHROPIC_API_KEY       A real key (recommended; held by authgw, never in claude) or the
                                  literal "oauth" for interactive claude auth login
          GITHUB_CONTRIBUTOR_TOKEN  Bot account token — fork publishing; used by the agent modes
          GITHUB_MAINTAINER_TOKEN   Push-access token — direct publishing for ship/pr (each push confirmed)
          CHOMPER_ALLOWED_OP_USER_IDS  Comma-separated OpenProject user ids allowed to trigger @chomper
          CHOMPER_ALLOWED_GH_USERS Comma-separated GitHub logins allowed to trigger gh-agent

        State (all in .chomper/, gitignored):
          work_packages/<host>/                    Per-instance WP state (namespaced by OpenProject host)
          work_packages/<host>/op_agent_filters.json  Saved search filters (created on first op-agent run)
          work_packages/<host>/<id>/               Per-WP folder: item.json, plan.md, pr.md, pr_url.txt
          pr_reviews/<owner>-<repo>/<number>/   Upstream-PR review state (gh-agent)
          openproject/        Isolated git worktree for fixes
          progress.txt        Progress log
          chat_session_id     Claude session for the current `chat` REPL (reset each run)
          claude-auth/        claude CLI config; holds OAuth login creds when no API key is set
          chomp.log           Full prompt + response log

      USAGE
    end
  end
end
