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
        id = wp_id_arg(argv[1])
        unless id.match?(/\A\d+\z/)
          $stderr.puts "Usage: ./chomper fix <work-package-id>"
          raise Chomper::FatalError
        end
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Fix ##{id} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        BacklogRunner.new(@ctx).fix(id)
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

    # Ids pasted from OpenProject often carry the "#" prefix ("#59942") —
    # accept it; the numeric validation downstream still rejects garbage.
    def wp_id_arg(arg)
      arg.to_s.strip.delete_prefix("#")
    end
  end
end
