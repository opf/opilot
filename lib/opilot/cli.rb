module OPilot
  # Argument parsing and dispatch for `./opilot <command>`. Everything a command
  # needs before its runner takes over happens here and nowhere else: validating
  # the arguments, loading the config, and stamping the log header. Help text
  # lives in UI, so a command's description and its "Usage:" line can't drift.
  class CLI
    def initialize(ctx)
      @ctx = ctx
    end

    def run(argv)
      @ui  = UI.new(@ctx)
      cmd  = argv[0].to_s
      rest = argv[1..].to_a

      return @ui.usage if cmd.empty? || help_flag?(cmd)
      # --help anywhere, not only as the first argument: `./opilot dev build --help`
      # would otherwise be parsed as a work-package id and die on the validator.
      return help_for(cmd) if rest.any? { |a| help_flag?(a) } && cmd != "chat"

      case cmd
      when "reset"  then @ui.reset
      when "usage"  then UsageRunner.new(@ctx).run
      # The agent loops — opilot's main mode. No arguments: they poll.
      when "agent"    then agent(rest)
      # Pre-group names for `agent op` / `agent gh`, kept because these are what
      # a service unit or a shell history calls, and the cost of breaking them is
      # a stopped agent.
      when "op-agent" then session("agent op") { Agent.new(@ctx).run }
      when "gh-agent" then session("agent gh") { GhAgent.new(@ctx).run }
      when "chat"     then session(cmd) { ChatRunner.new(@ctx).run(rest.join(" ")) }
      # The command groups. `dev` and `pd` are the two specializations — the kind
      # of work opilot does; `op` is an integration — the system it reads.
      when "dev"      then dev(rest)
      when "pd"       then pd(rest)
      when "op"       then op(rest)
      when "appsignal" then appsignal(rest)
      else
        $stderr.puts "Unknown argument: #{cmd}"
        @ui.usage
        raise OPilot::FatalError
      end
    end

    private

    def help_flag?(arg)
      %w[--help -h].include?(arg)
    end

    # A group answers for itself, so `./opilot dev --help` doesn't print the
    # whole screen to show five commands.
    def help_for(cmd)
      case cmd
      when "agent", "op-agent", "gh-agent" then @ui.agent_usage
      when "dev" then @ui.dev_usage
      when "pd" then @ui.pd_usage
      when "op" then @ui.op_usage
      when "appsignal" then @ui.appsignal_usage
      else @ui.usage
      end
    end

    # `agent` is both a group and opilot's main entry point: bare `./opilot
    # agent` runs both loops, so the group's default is to act rather than to
    # print help (`agent --help` does that).
    def agent(args)
      case args[0].to_s
      when ""   then session("agent")    { CombinedAgent.new(@ctx).run }
      when "op" then session("agent op") { Agent.new(@ctx).run }
      when "gh" then session("agent gh") { GhAgent.new(@ctx).run }
      else
        $stderr.puts "unknown agent subcommand #{args[0].inspect}"
        @ui.agent_usage
        raise OPilot::FatalError
      end
    end

    # `dev` is the software-development specialization: one pipeline named by
    # where each verb stops — plan ⊂ commit ⊂ build. `build` and `refresh` are
    # the words `@opilot` already takes, so one operation has one name.
    def dev(args)
      # A bare `./opilot dev` is a request for help, so answer it before
      # load_config! can fail at it for an unrelated reason.
      return @ui.dev_usage if args.empty?
      sub, *rest = args
      case sub
      # `dev fix` mirrors `@opilot fix`; logged and reported as `build`.
      when "build", "fix" then with_ids("dev build", rest) { |ids| FixRunner.new(@ctx).ship_ids(*ids) }
      when "commit"       then with_ids("dev commit", rest) { |ids| FixRunner.new(@ctx).commit_ids(*ids) }
      when "plan"         then with_ids("dev plan", rest) { |ids| FixRunner.new(@ctx).plan_ids(*ids) }
      when "refresh"      then refresh(rest)
      # Reads .opilot/ only — no config, no network, no log header.
      when "status"       then @ui.status
      else
        $stderr.puts "unknown dev subcommand #{sub.inspect}"
        @ui.dev_usage
        raise OPilot::FatalError
      end
    end

    # Everything that talks to OpenProject, GitHub, or the LLM comes through here:
    # load the config, then stamp exactly one log header in the shared format
    # ("=== <command> [targets] <timestamp> ==="). Per-command header wording had
    # drifted into five different shapes ("Session", "GH Session", "PR refresh"…),
    # which made chomp.log awkward to grep.
    def session(name, targets = [])
      @ctx.load_config!
      header = [name, *targets].join(" ")
      @ctx.log_file.open("a") { |f| f.puts "\n=== #{header} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      yield
    end

    # `build` / `commit` / `plan`: a list of work-package ids, validated before
    # anything loads or connects.
    def with_ids(name, args)
      ids = args.map { |a| wp_id_arg(a) }
      if ids.empty? || ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
        Helpers.usage!(name, "<work-package-id>...", "e.g. 59942 or PROJ-123 STC-7")
      end
      session(name, ids.map { |id| Helpers.wp_label(id) }) { yield ids }
    end

    # Refresh shipped PRs by work-package id and/or pasted PR URL (a URL resolves
    # to its WP via opilot's own state, else via the ticket link in the PR body).
    def refresh(args)
      targets = args.map(&:strip).map { |a| a.match?(%r{\Ahttps?://}) ? a : wp_id_arg(a) }
      unless targets.any? && targets.all? { |t| t.match?(Helpers::WP_ID_PATTERN) || pr_url?(t) }
        Helpers.usage!("dev refresh", "<work-package-id | pr-url>...",
                       "e.g. 59942, PROJ-123, or https://github.com/opf/openproject/pull/123")
      end
      session("dev refresh", targets.map { |t| t.match?(Helpers::WP_ID_PATTERN) ? Helpers.wp_label(t) : t }) do
        PrRunner.new(@ctx).run(*targets)
      end
    end

    def pr_url?(target)
      !!(Clients::GitHub.repo_from_url(target) && Clients::GitHub.pr_number_from_url(target))
    end

    # `op` reads the OpenProject API directly; OpRunner owns its own dispatch,
    # like PD::Runner. Deliberately NOT in #session: its stdout is JSON for a
    # pipe, so no log header, and it loads only the OpenProject credentials.
    def op(args)
      return @ui.op_usage if args.empty?
      OpRunner.new(@ctx).run(args)
    end

    # `appsignal` is an integration — the system it reads — so it sits beside
    # `op` rather than under `dev`. Unlike `op` it goes through #session: `fix`
    # calls the LLM and opens a PR, so it wants the full config and a log header.
    def appsignal(args)
      return @ui.appsignal_usage if args.empty?
      session("appsignal", args.first(2)) { AppSignalRunner.new(@ctx).run(args) }
    end

    # `pd` is the product-development (spec-driven) pipeline; PD::Runner owns its
    # subcommand dispatch and its own flags (--repo, --doc-id).
    def pd(args)
      # A bare `./opilot pd` is a request for help, so answer it before
      # load_config! can fail at it for an unrelated reason.
      return @ui.pd_usage if args.empty?
      # Required here rather than at boot: no other command touches the pipeline.
      # The intake converter (roo, nokogiri, rubyzip) is deliberately NOT pulled
      # in — PD::Runner#intake_client requires it on first use, so the stages
      # that never read a document don't pay for it.
      require "opilot/pd"
      session("pd", args.first(1)) { PD::Runner.new(@ctx).run(args) }
    end

    # Ids pasted from OpenProject often carry the "#" prefix ("#59942",
    # "#PROJ-123") — accept it, and upcase semantic ids typed in lowercase
    # ("proj-123"); the WP_ID_PATTERN validation downstream rejects garbage.
    def wp_id_arg(arg)
      id = arg.to_s.strip.delete_prefix("#")
      id.match?(/\A[A-Za-z][A-Za-z0-9_]*-\d+\z/) ? id.upcase : id
    end
  end
end
