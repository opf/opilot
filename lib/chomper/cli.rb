module Chomper
  class CLI
    def initialize(ctx)
      @ctx = ctx
    end

    def run(argv)
      cmd = argv[0] || ""
      ui  = UI.new(@ctx)

      case cmd
      when "", "--help", "-h"
        ui.usage
      when "status"
        ui.status
      when "reset"
        ui.reset
      when "agent"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Combined Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        CombinedAgent.new(@ctx).run
      when "op-agent"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        Agent.new(@ctx).run
      when "gh-agent"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== GH Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        GhAgent.new(@ctx).run
      when "chat"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Chat #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        ChatRunner.new(@ctx).run(argv[1..].to_a.join(" "))
      when "fix"
        with_ids(argv, "Fix", "fix") { |ids| FixRunner.new(@ctx).fix(*ids) }
      when "plan"
        with_ids(argv, "Plan", "plan") { |ids| FixRunner.new(@ctx).plan_ids(*ids) }
      when "pull"
        pull(argv)
      else
        $stderr.puts "Unknown argument: #{cmd}"
        ui.usage
        raise Chomper::FatalError
      end
    end

    private

    # `pull` mirrors work packages into the local cache for later `chat`, without
    # planning or shipping. With ids it fetches exactly those (validated like
    # fix/plan); with no ids it runs the filter wizard and mirrors every match.
    def pull(argv)
      ids = argv[1..].to_a.map { |a| wp_id_arg(a) }
      if ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
        $stderr.puts "Usage: ./chomper pull [<work-package-id>...]   (ids, or none to use saved/prompted filters)"
        raise Chomper::FatalError
      end
      @ctx.load_config!
      header = ids.empty? ? "by filter" : ids.map { |id| Helpers.wp_label(id) }.join(", ")
      @ctx.log_file.open("a") { |f| f.puts "\n=== Pull #{header} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      PullRunner.new(@ctx).run(*ids)
    end

    # Shared setup for the id-based commands (`fix`, `plan`): validate the ids,
    # load config, write a log header, then yield the ids to the runner call.
    def with_ids(argv, label, usage)
      ids = argv[1..].to_a.map { |a| wp_id_arg(a) }
      if ids.empty? || ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
        $stderr.puts "Usage: ./chomper #{usage} <work-package-id>...   (e.g. 59942 or PROJ-123 STC-7)"
        raise Chomper::FatalError
      end
      @ctx.load_config!
      labels = ids.map { |id| Helpers.wp_label(id) }.join(", ")
      @ctx.log_file.open("a") { |f| f.puts "\n=== #{label} #{labels} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      yield ids
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
