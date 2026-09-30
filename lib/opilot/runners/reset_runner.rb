module OPilot
  # `./opilot reset` — deletes .opilot/ after a confirmation.
  class ResetRunner
    def initialize(ctx)
      @ctx = ctx
    end

    def run
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
  end
end
