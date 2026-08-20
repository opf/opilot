require "json"
require "rainbow"

module OPilot
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
        # Only work packages opilot has acted on — not every polled (cached) WP.
        # options.json counts: opilot answered with implementation options and is
        # waiting for a number, which is action taken and work still open.
        next unless (dir / "plan.md").exist? || (dir / "pr.md").exist? ||
                    (dir / "options.json").exist? || pr_files.any?
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

    def reset
      puts ""
      puts "This will delete .opilot/ entirely (each repo is a standalone clone,"
      puts "so nothing outside .opilot/ is touched)."
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

    # The agent loops. `./opilot agent` with no subcommand runs both — that is
    # how opilot is normally run, so the group's bare form acts instead of
    # printing help the way `dev`/`pd` do.
    def agent_commands
      <<~AGENT.strip
        ./opilot agent
            Run both loops together: PRs first, then work packages.

        ./opilot agent op
            OpenProject only: act on @opilot comments.

        ./opilot agent gh
            GitHub only: opilot's own PRs (reply, write code when asked, fix
            failing CI) and upstream PRs that @-mention it (reply-only).
      AGENT
    end

    # `./opilot agent --help`, or a bad subcommand.
    def agent_usage_text
      <<~USAGE.strip
        Usage: ./opilot agent [op | gh]

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
        Triggers — on a work package:  @opilot build | grill | summarize, or
                                       anything else to just talk. build offers
                                       numbered options when a fix has more than
                                       one shape; reply `build <n>` to build one
                                       (one alias: fix)
                   on an opilot PR:    any @opilot comment gets a reply — and
                                       code, if asked; refresh is `dev refresh`;
                                       close closes the PR without a merge
      TRIGGERS
    end

    # The `dev` command list. Each entry is the whole command, so a line can be
    # copied straight to a shell; the reasoning belongs in CLAUDE.md.
    def dev_commands
      <<~DEV.strip
        The first three are one pipeline, named by where each one stops:

        ./opilot dev plan <id>...
            Plan with approval, then stop.

        ./opilot dev commit <id>...
            Plan, approve, implement, commit locally. Nothing pushed, no PR.

        ./opilot dev build <id>...
            Same, then open a draft PR from the bot's fork; picks up a branch an
            earlier commit left behind. (`dev fix` is an alias.)

        ./opilot dev refresh <id | pr-url>...
            Refresh a shipped PR: merge the base branch in, fix failing CI,
            address new review comments, push (with confirmation). Same thing
            `@opilot refresh` does on the PR itself.

        ./opilot dev status
            What opilot has planned or shipped, read from .opilot/.
      DEV
    end

    # The `op` command list: one entry per Clients::OpenProject read method, so
    # this table and that class stay checkable against each other by eye.
    def op_commands
      <<~OP.strip
        ./opilot op me                        who the token authenticates as

        ./opilot op wp get <id>               one work package (alias: inspect)
        ./opilot op wp list [flags]           search — see the flags below
        ./opilot op wp activities <id>        its comments and history
        ./opilot op wp reactions <id>         emoji reactions on its activities
        ./opilot op wp relations <id>         relations it takes part in

        ./opilot op project get <id>          one project (alias: inspect)
        ./opilot op project types <id>        the work-package types it allows
        ./opilot op status list               every status on the instance

        ./opilot op doc list <project-id>     documents in a project
        ./opilot op doc get <id>              one document (alias: inspect)
        ./opilot op doc attachments <id>      its attachments
        ./opilot op doc download <url> --out <path>
                                              attachment bytes, written to a file

        Flags for `wp list`:
          --filter <field>~<value>            repeatable; `~` contains, `=` equals
          --filter-json <json>                raw filters JSON, for anything else
          --page <n> / --page-size <n>        default 1 / 50
      OP
    end

    # `./opilot op` with no (or a bad) subcommand, and `op --help`.
    def op_usage_text
      <<~USAGE.strip
        Usage: ./opilot op <resource> <action>

        Read the OpenProject API directly — one command per operation, for
        checking what the API actually returns. Output is JSON on stdout, so it
        pipes: `./opilot op wp get 59942 | jq .subject`.

        #{indent(op_commands, 2)}

        Read-only by design, so a read-scoped OPENPROJECT_TOKEN is enough.
        Ids may be numeric or semantic (59942, PROJ-123) and may carry a "#".
        `wp relations` resolves to the numeric id itself — the API filter behind
        it takes no other kind. A failed request exits 1 with the response body
        still on stdout; with `| jq`, add `set -o pipefail` to see that status.
      USAGE
    end

    def op_usage
      puts ""
      puts op_usage_text
      puts ""
    end

    # `./opilot wp` with no (or a bad) subcommand, and `wp --help`.
    def dev_usage_text
      <<~USAGE.strip
        Usage: ./opilot dev <command>

        Software development: take a work package from a plan to a draft PR.

        #{indent(dev_commands, 2)}

        Ids may carry a pasted "#" (#59942) and semantic ids may be lowercase.
        To read a work package without working on it, use `./opilot op wp get <id>`.
      USAGE
    end

    def dev_usage
      puts ""
      puts dev_usage_text
      puts ""
    end

    # The `pd` command list. It lives here rather than in PD::Runner so that
    # `--help`, a bare `./opilot pd`, and a malformed pd invocation all print
    # the same text: the two copies had already drifted (the top-level help was
    # missing `generate-wp` and `implement` entirely).
    def pd_commands
      <<~PD.strip
        ./opilot pd init <project-id>
            Resolve the OpenProject ids and seed the spec store. Preflight; re-runnable.

        ./opilot pd intake <project-id> <change-id> [--doc-id <id>]...
            Mirror OpenProject Documents — attachments converted — into the
            change's intake/. Without --doc-id, every document in the project.

        ./opilot pd propose <change-id>
            Write the OpenSpec proposal from that intake and open the spec PR that
            is the approval gate. Revise it with `@opilot <feedback>` there.

        ./opilot pd generate-wp <change-id>
            Create the #{@ctx.pd_parent_type} plus one #{@ctx.pd_child_type} per tasks.md section.
            Running this is the approval signal; re-runnable.

        ./opilot pd implement <wp-id>...
            Build one generated work package from its spec: branch, commit, draft
            PR. The change is resolved from the id.
      PD
    end

    # `./opilot pd` with no (or a bad) subcommand, and `pd --help`.
    def pd_usage_text
      <<~USAGE.strip
        Usage: ./opilot pd <command>

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

        Usage: ./opilot <command> [arguments]

        Agent mode — how opilot is normally run (polls every 20s):
          ./opilot agent            watch OpenProject and GitHub, and act

        #{indent(triggers, 2)}

        Terminal:
          ./opilot dev <command>    software development: plan, commit, build, refresh, status
          ./opilot pd <command>     product development: the spec-driven pipeline
          ./opilot op <command>     read the OpenProject API directly (JSON out)
          ./opilot chat [message]   read-only chat about your local mirrors
          ./opilot usage            Inference spend (OpenRouter), else the configured upstream
          ./opilot reset            delete .opilot/, clones included

        `./opilot dev`, `./opilot pd` and `./opilot op` list their own commands, and
        --help works after any of them. Configuration lives in .env (the first run sets it up)
        and state in .opilot/ — both are documented in README.md.

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
