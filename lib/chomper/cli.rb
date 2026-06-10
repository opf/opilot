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
      when "backlog"
        sub = argv[1]
        unless sub.nil? || %w[show triage].include?(sub)
          $stderr.puts "Unknown argument: backlog #{sub}"
          ui.usage
          raise Chomper::FatalError
        end
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Backlog #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        runner = BacklogRunner.new(@ctx)
        case sub
        when "show"   then runner.show
        when "triage" then runner.triage
        else               runner.run
        end
      else
        $stderr.puts "Unknown argument: #{cmd}"
        ui.usage
        raise Chomper::FatalError
      end
    end
  end
end
