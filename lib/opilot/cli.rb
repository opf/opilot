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
      # --help anywhere, not only as the first argument: `./opilot wp ship --help`
      # would otherwise be parsed as a work-package id and die on the validator.
      return help_for(cmd) if rest.any? { |a| help_flag?(a) } && cmd != "chat"

      case cmd
      when "status" then @ui.status
      when "reset"  then @ui.reset
      when "usage"  then UsageRunner.new(@ctx).run
      # The agent loops — opilot's main mode. No arguments: they poll.
      when "agent"    then agent(rest)
      # Pre-group names for `agent op` / `agent gh`. Kept working rather than
      # redirected like the moved `wp` verbs: these are what a service unit or a
      # shell history calls, and the cost of breaking them is a stopped agent.
      when "op-agent" then session("agent op") { Agent.new(@ctx).run }
      when "gh-agent" then session("agent gh") { GhAgent.new(@ctx).run }
      when "chat"     then session(cmd) { ChatRunner.new(@ctx).run(rest.join(" ")) }
      # The command groups, each owning its own subcommands and help.
      when "wp"       then wp(rest)
      when "pd"       then pd(rest)
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

    # A group answers for itself, so `./opilot wp --help` doesn't print the
    # whole screen to show five commands.
    def help_for(cmd)
      case cmd
      when "agent", "op-agent", "gh-agent" then @ui.agent_usage
      when "wp" then @ui.wp_usage
      when "pd" then @ui.pd_usage
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

    # `wp` is the work-package group: everything keyed on a work-package id.
    def wp(args)
      # A bare `./opilot wp` is a request for help, so answer it before
      # load_config! can fail at it for an unrelated reason.
      return @ui.wp_usage if args.empty?
      sub, *rest = args
      case sub
      # `wp fix` stays as an alias of `wp ship`, logged and reported as `ship`.
      when "ship", "fix" then with_ids("wp ship", rest) { |ids| FixRunner.new(@ctx).ship_ids(*ids) }
      when "build"       then with_ids("wp build", rest) { |ids| FixRunner.new(@ctx).build_ids(*ids) }
      when "plan"        then with_ids("wp plan", rest) { |ids| FixRunner.new(@ctx).plan_ids(*ids) }
      # `wp pull` with no ids falls back to the saved/prompted filter wizard.
      when "pull"        then with_ids("wp pull", rest, allow_empty: true) { |ids| PullRunner.new(@ctx).run(*ids) }
      when "pr"          then pr(rest)
      else
        $stderr.puts "unknown wp subcommand #{sub.inspect}"
        @ui.wp_usage
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

    # `ship` / `build` / `plan` / `pull`: a list of work-package ids, validated
    # before anything loads or connects. `pull` alone accepts none (it then runs
    # the filter wizard).
    def with_ids(name, args, allow_empty: false)
      ids = args.map { |a| wp_id_arg(a) }
      if (ids.empty? && !allow_empty) || ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
        arg_spec = allow_empty ? "[<work-package-id>...]" : "<work-package-id>..."
        usage!(name, arg_spec, "e.g. 59942 or PROJ-123 STC-7")
      end
      session(name, ids.empty? ? ["by filter"] : ids.map { |id| Helpers.wp_label(id) }) { yield ids }
    end

    # `wp pr` refreshes shipped PRs, targeted by work-package id and/or pasted
    # GitHub PR URL (a URL is resolved to its WP via opilot's own state, else via
    # the OpenProject ticket link at the top of the PR description).
    def pr(args)
      targets = args.map(&:strip).map { |a| a.match?(%r{\Ahttps?://}) ? a : wp_id_arg(a) }
      unless targets.any? && targets.all? { |t| t.match?(Helpers::WP_ID_PATTERN) || pr_url?(t) }
        usage!("wp pr", "<work-package-id | pr-url>...",
               "e.g. 59942, PROJ-123, or https://github.com/opf/openproject/pull/123")
      end
      session("wp pr", targets.map { |t| t.match?(Helpers::WP_ID_PATTERN) ? Helpers.wp_label(t) : t }) do
        PrRunner.new(@ctx).run(*targets)
      end
    end

    def pr_url?(target)
      !!(Clients::GitHub.repo_from_url(target) && Clients::GitHub.pr_number_from_url(target))
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

    # One "Usage:" shape for every command, so a bad invocation reads the same
    # whichever one it was.
    def usage!(name, arg_spec, example = nil)
      $stderr.puts "Usage: ./opilot #{name} #{arg_spec}#{example ? "   (#{example})" : ""}"
      raise OPilot::FatalError
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
