require "rainbow"

module OPilot
  class UI
    def initialize(ctx)
      @ctx = ctx
    end

    # The agent loops. `./opilot agent` with no subcommand runs both — that is
    # how opilot is normally run, so the group's bare form acts instead of
    # printing help the way `dev`/`pd` do.
    def agent_commands
      <<~AGENT.strip
        ./opilot agent
            Run every loop in one process, in this order on each tick: PRs,
            work packages, then Matrix. PRs need GITHUB_CONTRIBUTOR_TOKEN;
            Matrix needs MATRIX_* in .env. A loop without its config is skipped.

        ./opilot agent op
            OpenProject only: act on @opilot comments.

        ./opilot agent gh
            GitHub only: opilot's own PRs (reply, write code when asked, fix
            failing CI) and upstream PRs that @-mention it (reply-only).

        ./opilot agent matrix
            Matrix only: chat in the configured room, and the @opilot words
            with the work package first: `build #1323` (needs
            OPILOT_ALLOWED_MATRIX_USERS).
      AGENT
    end

    # `./opilot agent --help`, or a bad subcommand.
    def agent_usage_text
      <<~USAGE.strip
        Usage: ./opilot agent [op | gh | matrix]

        #{indent(agent_commands, 2)}

        #{indent(triggers, 2)}

        Every loop polls every 20s and is gated by the allowlists in .env.
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
        Triggers — on a work package:  @opilot build | create wp | grill |
                                       summarize | health, or just talk.
                                       build offers numbered options when a fix
                                       has more than one shape; reply `build <n>`
                                       to build one (one alias: fix). create wp
                                       splits something out of the thread into a
                                       new work package — it needs an allowlist
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

        ./opilot dev health <id>...
            Check a work package for drift: description against comments,
            pictures, related work packages, status, linked PRs and commits.
            Prints the report and posts nothing. Same as `@opilot health`.

        ./opilot dev refresh <id | pr-url>...
            Refresh a shipped PR: merge the base branch in, fix failing CI,
            address new review comments, push (with confirmation). Same thing
            `@opilot refresh` does on the PR itself.

        ./opilot dev status
            What opilot has planned or shipped, read from .opilot/.
      DEV
    end

    # The `op` command list: one entry per Clients::OpenProject::Client method `op`
    # exposes, so this table and that class stay checkable against each other by
    # eye. All reads but one — `wp create` writes; the two forms save nothing.
    def op_commands
      <<~OP.strip
        ./opilot op me                        who the token authenticates as

        ./opilot op wp get <id>               one work package (alias: inspect)
        ./opilot op wp list [flags]           search — see the flags below
        ./opilot op wp activities <id>        its comments and history
        ./opilot op wp reactions <id>         emoji reactions on its activities
        ./opilot op wp relations <id> [--page <n>] [--page-size <n>]
                                              relations it takes part in
        ./opilot op wp assignees <id>         who may be assigned to it
        ./opilot op wp attachments <id>       files attached to it (not to its
                                              comments — see `attachment get`)
        ./opilot op wp prs <id>               pull requests the GitHub
                                              integration linked to it
        ./opilot op wp schema --project <id> --type <name|id>
                                              every field of that pair, with the
                                              key a payload uses (customField12)
        ./opilot op wp create [flags]         create one — see the flags below
        ./opilot op wp form [flags]           what a project requires, and what
                                              it allows — creates nothing
                                              (--required for just that list)
        ./opilot op wp update-form <id> [flags]
                                              would this change be accepted?
                                              saves nothing (--field, --link,
                                              --payload-json as for `wp create`)

        ./opilot op project get <id>          one project (alias: inspect)
        ./opilot op project list [flags]      projects — the `wp list` flags
        ./opilot op project types <id>        the work-package types it allows
        ./opilot op project versions <id>     the versions it can use
        ./opilot op status list               every status on the instance
        ./opilot op priority list             every priority on the instance
        ./opilot op principal list [flags]    users, groups, placeholders — the
                                              `wp list` flags (name~jane)
        ./opilot op user get <id>             one user (alias: inspect)
        ./opilot op attachment get <id>       one attachment's metadata, from any
                                              container (alias: inspect)
        ./opilot op cf items <id>             the values a hierarchy custom
                                              field allows

        ./opilot op doc list <project-id> [--page <n>] [--page-size <n>]
                                              documents in a project
        ./opilot op doc get <id>              one document (alias: inspect)
        ./opilot op doc attachments <id>      its attachments
        ./opilot op doc download <url> --out <path>
                                              attachment bytes, written to a file

        Flags for `wp list`, `project list` and `principal list`:
          --filter <field>~<value>            repeatable; `~` contains, `=` equals.
                                              In `wp list`, status, priority,
                                              assignee, author and responsible
                                              take a name or an id (status=New)
          --filter-json <json>                raw filters JSON, for anything else:
                                              a list of {"<field>":{"operator",
                                              "values"}} objects
          --page <n> / --page-size <n>        default 1 / 50 (100 for the other two);
                                              the instance may cap the page size

        Flags for `wp create` (--project, --type and --subject are required;
        `wp form` takes the same ones and needs no --subject):
          --project <id>                      project id or identifier
          --type <name|id>                    a name is resolved on the project;
                                              `op project types <id>` lists them
          --subject <text>                    the title
          --description <text>                markdown body
          --description-file <path|->         the body from a file, or "-" for stdin
          --field <name>=<value>              repeatable; a plain field, e.g. a
                                              required customField12
          --link <name>=<href>                repeatable; a field whose value is a
                                              resource (a select, list, user, version).
                                              Repeat one name for a multi-value field
          --relates <id>                      relate the new one to this work package
          --parent <id>                       create it as a child of this one
          --payload-json <json>               the whole v3 body, instead of the flags
          --dry-run                           ask OpenProject whether the payload
                                              works, and create nothing
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

    # `./opilot appsignal` with no (or a bad) subcommand, and `appsignal --help`.
    def appsignal_usage_text
      <<~USAGE.strip
        Usage: ./opilot appsignal <command> [flags]

        Turn a production error into a work package and a draft PR, or read
        AppSignal directly.

          ./opilot appsignal fix <incident-number> [--project <id>] [--type <name>] [--app <id-or-name>]
              Read the incident — message, backtrace, and the request payload
              that triggered it — write one work package, create it, then plan
              and build the fix, with the same prompts as `./opilot dev build`.
              --type names the work-package type and overrides the one opilot
              picks from the incident.

        A bare number is `fix`: `./opilot appsignal 2025`.

        `fix` sends production error data to the model, so it RUNS ONLY against
        a private inference endpoint and refuses otherwise. See
        OPILOT_INFERENCE_URL in .env.example.

        The read commands print JSON on stdout, call no model, and change nothing:

          ./opilot appsignal apps
              The apps your token can see: id, name, environment.
          ./opilot appsignal incident list [--state open|closed|wip|all] [--sort last|total|id]
                                           [--search <text>] [--namespace <name>]
                                           [--limit <n>] [--page <n>] [--app <id-or-name>]
              One page of exception incidents, with the total. Defaults: open,
              most recent first, 25 a page.
          ./opilot appsignal incident get <incident-number> [--app <id-or-name>]
              The incident as `fix` reads it — metadata, request payload and
              backtrace. The payload can hold user data.

        Set APPSIGNAL_API_TOKEN (a personal API token, from your AppSignal
        personal settings) and APPSIGNAL_APP_ID — an app id or its name. With no
        app set, opilot lists the apps your token can see.
      USAGE
    end

    def appsignal_usage
      puts ""
      puts appsignal_usage_text
      puts ""
    end

    def usage
      puts <<~USAGE

        Usage: ./opilot <command> [arguments]

        Agent mode — how opilot is normally run (polls every 20s):
          ./opilot agent            watch OpenProject, GitHub and Matrix, and act

        #{indent(triggers, 2)}

        Terminal:
          ./opilot dev <command>    software development: plan, commit, build, health, refresh, status
          ./opilot pd <command>     product development: the spec-driven pipeline
          ./opilot op <command>     read the OpenProject API directly (JSON out)
          ./opilot appsignal <cmd>  read production errors, or turn one into a work package and a PR
          ./opilot chat [message]   read-only chat about your local mirrors
          ./opilot usage            Inference spend (OpenRouter), else the configured upstream
          ./opilot reset            delete .opilot/, clones included

        Every group lists its own commands, and --help works after any of them.
        Config lives in .env (the first run sets it up), state in .opilot/ — see README.md.

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
