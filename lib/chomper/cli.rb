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
        @ctx.log_file.open("a") { |f| f.puts "\n=== Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        Agent.new(@ctx).run
      when "fix"
        ids = argv[1..].to_a.map { |a| wp_id_arg(a) }
        if ids.empty? || ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
          $stderr.puts "Usage: ./chomper fix <work-package-id>...   (e.g. 59942 or PROJ-123 STC-7)"
          raise Chomper::FatalError
        end
        @ctx.load_config!
        labels = ids.map { |id| Helpers.wp_label(id) }.join(", ")
        @ctx.log_file.open("a") { |f| f.puts "\n=== Fix #{labels} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        BacklogRunner.new(@ctx).fix(*ids)
      when "backlog"
        sub = argv[1]
        unless sub.nil? || %w[show triage process skip].include?(sub)
          $stderr.puts "Unknown argument: backlog #{sub}"
          ui.usage
          raise Chomper::FatalError
        end
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Backlog #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        runner = BacklogRunner.new(@ctx)
        case sub
        when "show"    then runner.show
        when "triage"  then runner.triage
        when "process" then runner.process
        when "skip"    then runner.skip(wp_id_arg(argv[2]))
        else                runner.run
        end
      else
        $stderr.puts "Unknown argument: #{cmd}"
        ui.usage
        raise Chomper::FatalError
      end
    end

    private

    # Ids pasted from OpenProject often carry the "#" prefix ("#59942",
    # "#PROJ-123") — accept it, and upcase semantic ids typed in lowercase
    # ("proj-123"); the WP_ID_PATTERN validation downstream rejects garbage.
    def wp_id_arg(arg)
      id = arg.to_s.strip.delete_prefix("#")
      id.match?(/\A[A-Za-z][A-Za-z0-9_]*-\d+\z/) ? id.upcase : id
    end
  end
end
