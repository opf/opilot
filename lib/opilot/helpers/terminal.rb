require "time"
require "rainbow"
require "tty-markdown"

module OPilot
  module Helpers
    # Console output and input: the log line, markdown rendering, the choice
    # prompt, and the polling-loop backstop.

    # One "Usage:" shape for every command, so a bad invocation reads the same
    # whichever one it was. A module function because CLI does not include
    # Helpers, and it was the second verbatim copy that proved the point.
    def self.usage!(name, arg_spec, example = nil)
      $stderr.puts "Usage: ./opilot #{name} #{arg_spec}#{example ? "   (#{example})" : ""}"
      raise OPilot::FatalError
    end

    # Turn a "how far back" answer into an ISO8601 cutoff. Accepts a relative
    # span ("1h", "2 days", "1 week", "1 month", "1 year"), an absolute time, or
    # blank/"now" (= now). Months and years use 30- and 365-day approximations,
    # which is plenty for a scan floor. Shared by the OpenProject agent (OpPull)
    # and the GitHub agent (GhPull) so the "scan from" prompt parses identically.
    def self.parse_scan_from(input)
      input = input.to_s.strip.downcase
      return Time.now.utc.iso8601 if input.empty? || input == "now"
      if (m = input.match(/\A(\d+)\s*([a-z]+)\z/))
        n = m[1].to_i
        # Classify on the whole unit, not the first letter: "m" is minutes but
        # "mo"/"month" is months, so a first-char test can't tell them apart.
        seconds = case m[2]
                  when "m", /\Amin(ute)?s?\z/   then n * 60
                  when /\Ah(our)?s?\z/           then n * 3600
                  when /\Ad(ay)?s?\z/            then n * 86400
                  when /\Aw(eek)?s?\z/           then n * 604800
                  when /\Amo(n(th)?)?s?\z/       then n * 2592000
                  when /\Ay(ear)?s?\z/           then n * 31536000
                  end
        return (Time.now - seconds).utc.iso8601 if seconds
      end
      begin
        Time.parse(input).utc.iso8601
      rescue ArgumentError
        puts "  Could not parse '#{input}' — defaulting to now"
        Time.now.utc.iso8601
      end
    end

    # Single source of truth for log-line timestamps — both the time format and
    # the bracket wrapping — so every line opilot writes shares one format.
    LOG_TIME_FORMAT = "%H:%M:%S"

    # Render Markdown as ANSI for the terminal — used both for the LLM's streamed
    # text and for re-displaying saved plans from disk, so they look the same.
    # Skipped when stdout isn't a tty (piped, captured by tests, redirected);
    # then the raw, cyan-tinted text is shown. Falls back to the raw text if
    # rendering raises (e.g. a partial fence).
    def render_markdown(text)
      return Rainbow(text).cyan unless $stdout.tty?
      TTY::Markdown.parse(text)
    rescue StandardError
      Rainbow(text).cyan
    end

    def log_timestamp
      Time.now.strftime(LOG_TIME_FORMAT)
    end

    def log_prefix
      "[ #{log_timestamp} ]"
    end

    def log_script(msg)
      prefix = log_prefix
      msg.each_line do |line|
        formatted = Rainbow("#{prefix} #{line.chomp}").bold
        @ctx.log_file.open("a") { |f| f.puts(formatted) }
        $stdout.puts(formatted)
      end
      $stdout.print(Rainbow("").gray) # set gray for subsequent docker output
      $stdout.flush
    end

    def strip_ansi(str)
      Rainbow.uncolor(str)
    end

    # Run one polling pass, surviving any uncaught failure. A long-running agent
    # must not die because a single poll hit a dropped connection or a flaky API
    # response — log it and let the loop retry on the next tick. The client-level
    # retries (Clients::HTTP / Clients::GitHub) handle the common transient
    # cases; this is the backstop for anything that still escapes. Ctrl-C is
    # unaffected: it exits via SystemExit, which is not a StandardError.
    def guarded_tick(label = "Poll")
      yield
    rescue => e
      log_script "#{label} failed (#{e.class}: #{e.message}) — retrying next tick"
    end

    # Calls the user back for an input prompt that typically follows a long
    # unattended the LLM run. OSC 9 posts a desktop notification in terminals
    # that support it (Ghostty, iTerm2, WezTerm, kitty); others drop the
    # sequence. The BEL after it rings the bell everywhere else (sound, dock
    # bounce, tab highlight — whatever the emulator is configured to do).
    def ping_terminal(message = "opilot is waiting for your input")
      $stdout.print("\e]9;#{message}\e\\\a")
      $stdout.flush
    end

    # One terminal choice prompt, shared by every [y]/[s]/[d]-style question.
    #
    # `choices` is { result => [accepted answers…] }, the FIRST answer of each
    # being its letter. The re-ask hint is built from those letters, so it cannot
    # drift from what the prompt accepts. `default:` is what an empty line means,
    # for the prompts that have an obvious yes.
    #
    # Prompts that accept free text (FixRunner#prompt_option_choice) or that ask
    # once without re-asking (ResetRunner#run) are deliberately not routed through here.
    def prompt_choice(label, choices, default: nil)
      table   = {}
      choices.each { |result, answers| Array(answers).each { |a| table[a] = result } }
      letters = choices.values.map { |answers| Array(answers).first }
      hint    = letters.length > 1 ? "#{letters[0..-2].join(", ")}, or #{letters.last}" : letters.first.to_s
      loop do
        print "  #{label}: "
        answer = $stdin.gets&.chomp&.downcase || ""
        return default if answer.empty? && default
        result = table[answer]
        return result if result
        puts "  Please enter #{hint}."
      end
    end
  end
end
