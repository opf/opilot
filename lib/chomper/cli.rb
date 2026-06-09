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
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Backlog #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        BacklogRunner.new(@ctx).run
      else
        $stderr.puts "Unknown argument: #{cmd}"
        ui.usage
        raise Chomper::FatalError
      end
    end
  end
end
