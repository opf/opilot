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
        puts "Nothing yet. Run ./chomper agent and mention @chomper on a work package."
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

    # The agent loops. `./chomper agent` with no subcommand runs both — that is
    # how chomper is normally run, so the group's bare form acts instead of
    # printing help the way `wp`/`pd` do.
    def agent_commands
      <<~AGENT.strip
        ./chomper agent
            Run both loops together: PRs first, then work packages.

        ./chomper agent op
            OpenProject only: act on @chomper comments, and on chomper being set
            as a work package's assignee.

        ./chomper agent gh
            GitHub only: chomper's own PRs (reply, write code when asked, fix
            failing CI) and upstream PRs that @-mention it (reply-only).
      AGENT
    end

    # `./chomper agent --help`, or a bad subcommand.
    def agent_usage_text
      <<~USAGE.strip
        Usage: ./chomper agent [op | gh]

        #{indent(agent_commands, 2)}

        #{indent(triggers, 2)}

        Both loops poll every 20s and are gated by the allowlists in .env.
        `op-agent` and `gh-agent` still work as aliases.
      USAGE
    end

    def agent_usage
      puts ""
      puts agent_usage_text
      puts ""
    end

    # What agent mode acts on, shown wherever agent mode is described — the
    # commands are useless without knowing what triggers them.
    def triggers
      <<~TRIGGERS.strip
        Triggers — on a work package:  @chomper ship | plan | approve | grill |
                                       summarize, or anything else to just talk
                                       (ship aliases: fix, prototype, build, pr,
                                       implement)
                   on a chomper PR:    any @chomper comment gets a reply — and
                                       code, if asked; refresh re-runs `wp pr`
      TRIGGERS
    end

    # The `wp` (work-package) command list. Every entry is spelled as the whole
    # command, so a line can be copied straight to a shell. One or two lines of
    # description each — the reasoning behind them belongs in CLAUDE.md, not on
    # someone's terminal.
    def wp_commands
      <<~WP.strip
        ./chomper wp plan <id>...
            Plan with approval, then stop.

        ./chomper wp build <id>...
            Plan, approve, implement, commit locally. Nothing pushed, no PR.

        ./chomper wp ship <id>...
            Same, then open a draft PR from the bot's fork; picks up a branch an
            earlier build committed. (`wp fix` is an alias.)

        ./chomper wp pr <id | pr-url>...
            Refresh a shipped PR: merge the base branch in, fix failing CI,
            address new review comments, push (with confirmation).

        ./chomper wp pull [<id>...]
            Mirror work packages into the local cache for later chat. With no
            ids, the filter wizard runs.
      WP
    end

    # `./chomper wp` with no (or a bad) subcommand, and `wp --help`.
    def wp_usage_text
      <<~USAGE.strip
        Usage: ./chomper wp <command>

        #{indent(wp_commands, 2)}

        Ids may carry a pasted "#" (#59942) and semantic ids may be lowercase.
      USAGE
    end

    def wp_usage
      puts ""
      puts wp_usage_text
      puts ""
    end

    # The `pd` command list. It lives here rather than in PD::Runner so that
    # `--help`, a bare `./chomper pd`, and a malformed pd invocation all print
    # the same text: the two copies had already drifted (the top-level help was
    # missing `generate-wp` and `implement` entirely).
    def pd_commands
      <<~PD.strip
        ./chomper pd init <project-id>
            Resolve the OpenProject ids and seed the spec store. Preflight; re-runnable.

        ./chomper pd intake <project-id> <change-id> [--doc-id <id>]...
            Mirror OpenProject Documents — attachments converted — into the
            change's intake/. Without --doc-id, every document in the project.

        ./chomper pd propose <change-id>
            Write the OpenSpec proposal from that intake and open the spec PR that
            is the approval gate. Revise it with `@chomper <feedback>` there.

        ./chomper pd generate-wp <change-id>
            Create the #{@ctx.pd_parent_type} plus one #{@ctx.pd_child_type} per tasks.md section.
            Running this is the approval signal; re-runnable.

        ./chomper pd implement <wp-id>...
            Build one generated work package from its spec: branch, commit, draft
            PR. The change is resolved from the id.
      PD
    end

    # `./chomper pd` with no (or a bad) subcommand, and `pd --help`.
    def pd_usage_text
      <<~USAGE.strip
        Usage: ./chomper pd <command>

        #{indent(pd_commands, 2)}

        change-id is author-chosen kebab-case (e.g. add-recurring-meetings).
        Every command takes --repo <name> to pick a repo from repos.json.
      USAGE
    end

    def pd_usage
      puts ""
      puts pd_usage_text
      puts ""
    end

    def usage
      puts <<~USAGE

        Usage: ./chomper <command> [arguments]

        Agent mode — how chomper is normally run (polls every 20s):
          ./chomper agent            watch OpenProject and GitHub, and act

        #{indent(triggers, 2)}

        Terminal:
          ./chomper wp <command>     work packages by id: plan, build, ship, pr, pull
          ./chomper pd <command>     product development: the spec-driven pipeline
          ./chomper chat [message]   read-only chat about your local mirrors
          ./chomper status           what chomper has planned or shipped
          ./chomper reset            delete .chomper/, clones included

        `./chomper wp` and `./chomper pd` list their own commands, and --help works
        after any of them. Configuration lives in .env (the first run sets it up)
        and state in .chomper/ — both are documented in README.md.

      USAGE
    end

    private

    # Indent a whole block for interpolation into a squiggly heredoc. The heredoc
    # strips its own literal indentation before the value is inserted, so the
    # block has to carry all of its own — including on the first line.
    def indent(text, spaces)
      pad = " " * spaces
      text.lines.map { |l| l.strip.empty? ? l : pad + l }.join
    end
  end
end
