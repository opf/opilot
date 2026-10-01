require "net/http"
require "uri"
require "json"
require "rainbow"
require "tty-markdown"
require "pathname"
require "securerandom"

module OPilot
  class Harness
    include Helpers

    # The pi run ended with an error. Text streamed before it is partial, not an answer.
    Error = Class.new(StandardError)

    # Must match ALLOWED_TOOL_GRANTS in server.js. grep/find/ls are always granted:
    # without them the model tries Bash find/grep, which is denied and kills the run.
    # pi-guards.ts limits bash to read-only git. See CLAUDE.md, Architecture: Harness.
    TOOLS_READ = "read,grep,find,ls,bash"
    TOOLS_IMPL = "read,grep,find,ls,bash,write,edit"

    # Only for roles marked `mcp` (roles.rb). Must match ALLOWED_TOOL_GRANTS in server.js.
    TOOLS_READ_OP = "#{TOOLS_READ},op_query"
    TOOLS_IMPL_OP = "#{TOOLS_IMPL},op_query"

    # This order must match server.js's ALLOWED_TOOL_GRANTS exactly, or the call 403s.
    def self.tools_for(base, op_mcp:, gh_mcp:)
      [base, ("op_query" if op_mcp), ("gh_query" if gh_mcp)].compact.join(",")
    end

    # Always <provider>/<model-id>; server.js picks the provider config from the prefix.
    # MODEL_HEAVY serves every session-bound phase, because a model switch mid-session
    # discards its context. MODEL_LIGHT is for stateless one-shots.
    MODEL_HEAVY  = ENV.fetch("OPILOT_MODEL_HEAVY", "openrouter/anthropic/claude-sonnet-5.5")
    MODEL_LIGHT  = ENV.fetch("OPILOT_MODEL_LIGHT", "openrouter/anthropic/claude-haiku-4.5")

    # Must stay the outer bound (ceiling + one idle window), or server.js's named
    # timeout becomes a bare Net::ReadTimeout. See CLAUDE.md, Harness container communication.
    def self.env_minutes(name, fallback)
      value = ENV.fetch(name, "").to_f
      value.positive? ? value : fallback
    end
    private_class_method :env_minutes

    READ_TIMEOUT = (
      (env_minutes("OPILOT_PI_MAX_RUN_MIN", 45) +
       env_minutes("OPILOT_PI_IDLE_TIMEOUT_MIN", 5) + 2) * 60
    ).round

    require_relative "roles"

    def initialize(ctx)
      @ctx = ctx
      @uri = URI(@ctx.harness_url)
    end

    # Cheap GET against server.js's health endpoint.
    def available?
      Net::HTTP.start(@uri.host, @uri.port, open_timeout: 2, read_timeout: 2) do |http|
        http.get("/health").is_a?(Net::HTTPSuccess)
      end
    rescue StandardError
      false
    end

    # Fail before any real work, not after ~30s of reconnect backoff and a bare SocketError.
    def ensure_available!
      return if available?
      raise OPilot::FatalError, <<~MSG.strip
        The harness container is not reachable at #{@ctx.harness_url}.
        Start it with `docker compose up -d --wait harness`, or run this through
        ./opilot (which starts it for the commands that need it).
      MSG
    end

    # Runs the LLM and returns its text. With session_file:, the runner owns the
    # session id: it reuses the file's or mints one, so a lost session starts fresh.
    def run(prompt, role:, tools: nil, model: MODEL_HEAVY, session_file: nil)
      known_id   = session_file&.exist? ? session_file.read.strip : ""
      session_id = known_id.empty? ? (SecureRandom.uuid if session_file) : known_id

      system = Prompts.charter(role)
      sys_header = Rainbow("#{log_prefix} PI SYSTEM (role: #{role})").bold
      puts sys_header
      log_append(sys_header)
      puts Rainbow(system).gray
      log_append(Rainbow(system).gray)

      header = Rainbow("#{log_prefix} PI PROMPT (model: #{model}, session: #{known_id.empty? ? "fresh" : known_id})").bold
      puts header
      log_append(header)
      puts Rainbow(prompt.strip).cyan
      log_append(Rainbow(prompt.strip).cyan)

      resp_header = Rainbow("#{log_prefix} PI RESPONSE").bold
      puts resp_header
      log_append(resp_header)

      text, started, error = http_stream(prompt, role: role, tools: tools, model: model, session_id: session_id, system: system)

      # Saved once pi has started, even on error, so a retry resumes with context.
      # Not before: session_resumable? reads the file as "the session holds the plan".
      if session_file && started && known_id.empty?
        log_append("session: #{session_id} → #{session_file}")
        session_file.write(session_id)
      end
      if error
        log_append("run failed: #{error}")
        raise Error, error
      end
      log_append(text)
      puts ""
      text
    end

    # Like run, but also writes ANSI-stripped output to outfile.
    def capture(prompt, role:, outfile:, tools: nil, model: MODEL_HEAVY, session_file: nil)
      text = run(prompt, role: role, tools: tools, model: model, session_file: session_file)
      Pathname(outfile).write(strip_ansi(text))
      text
    end

    private

    def http_stream(prompt, role:, tools:, model:, system:, session_id: nil)
      attempts = 0
      begin
        attempts += 1
        text_parts          = []
        buffer              = "".dup
        at_line_start       = true
        after_tool          = false
        started             = false
        final_result        = nil
        error               = nil
        error_subtype       = nil
        exit_info           = nil

        req = Net::HTTP::Post.new(@uri)
        req["X-Harness-Role"]    = role.to_s
        req["X-Harness-Tools"]   = tools      if tools
        req["X-Harness-Model"]   = model      if model
        req["X-Harness-Session"] = session_id if session_id
        # The role's charter and grant rules, as pi's system prompt: every turn
        # carries them, and a resumed session never keeps an earlier role's.
        req["X-Harness-System"]  = [system].pack("m0")
        req.body = prompt

        Net::HTTP.start(@uri.host, @uri.port, read_timeout: READ_TIMEOUT) do |http|
          http.request(req) do |res|
            unless res.is_a?(Net::HTTPSuccess)
              # e.g. 403 "unknown tool grant" from an old harness image.
              error = "harness server HTTP #{res.code}: #{res.body.to_s.strip}"
              $stdout.puts Rainbow("  ✗ #{error}").red
              next
            end
            res.read_body do |chunk|
              buffer << chunk
              while (line = buffer.slice!(/\A[^\n]*\n/))
                parsed = JSON.parse(line.chomp) rescue next
                case parsed["type"]
                when "session_id"
                  started = true
                when "exit"
                  # server.js's final diagnostic: exit code/signal + stderr tail.
                  exit_info = parsed
                when "result"
                  # An error here means the run died mid-way; the text is partial.
                  if parsed["is_error"] || parsed["subtype"].to_s.start_with?("error")
                    error_subtype = parsed["subtype"].to_s
                    error = parsed["result"].to_s.strip
                    error = error_subtype if error.empty?
                    $stdout.puts "" unless at_line_start
                    $stdout.puts Rainbow("  ✗ #{error}").red
                    at_line_start = true
                  else
                    # The last message only, so callers get the conclusion, not the narration.
                    final_result = parsed["result"]
                  end
                when "assistant"
                  (parsed.dig("message", "content") || []).each do |part|
                    case part["type"]
                    when "tool_use"
                      $stdout.puts "" unless at_line_start
                      summary = tool_call_summary(part["name"], part["input"])
                      $stdout.puts Rainbow("  #{part["name"]}  #{summary}").cyan
                      at_line_start = true
                      after_tool    = true
                    when "text_delta", "thinking_delta"
                      # Printed raw as it streams, so long thinking is visible. Not kept:
                      # "text" below carries the full block.
                      chunk = part["text"].to_s
                      next if chunk.empty?
                      print(part["type"] == "thinking_delta" ? Rainbow(chunk).gray : chunk)
                      at_line_start = chunk.end_with?("\n")
                    when "text"
                      if after_tool && !text_parts.empty? && !text_parts.last.end_with?("\n")
                        text_parts << "\n\n"
                      end
                      after_tool = false
                      # Already shown via text_delta; kept for the return value and log.
                      text_parts << part["text"]
                    end
                  end
                end
              end
            end
          end
        end
      rescue SocketError, EOFError, Errno::ECONNRESET, Errno::EPIPE => e
        if attempts < 3
          delay = attempts * 10
          $stdout.puts Rainbow("\n  ⚠ #{e.class} (attempt #{attempts}) — retrying in #{delay}s…").yellow
          sleep delay
          retry
        end
        raise
      end

      text = final_result.to_s.strip.empty? ? text_parts.join : final_result

      # A non-zero exit with no result event is a crash, not an empty answer.
      if !error && exit_info && exit_info["timed_out"]
        # "idle" (wedged: retry) and "max" (too big: ask for less) need different answers.
        error = case exit_info["timeout_kind"]
                when "idle" then "pi run stalled with no output and was killed"
                when "max"  then "pi run hit the maximum run time and was killed"
                else "pi run timed out and was killed"
                end
      elsif !error && exit_info && exit_info["code"].to_i != 0 && text.to_s.strip.empty?
        error = "pi exited #{exit_signal_desc(exit_info)} with no result"
      end

      # For `error_during_execution`, stderr holds the only real cause.
      error = decorate_error(error, error_subtype, exit_info) if error

      [text, started, error]
    end

    # Adds the subtype, exit code/signal and stderr tail to the error message.
    def decorate_error(error, subtype, exit_info)
      parts = [error]
      parts << "(#{subtype})" if subtype.to_s.start_with?("error") && error != subtype
      if exit_info
        parts << "[exit #{exit_signal_desc(exit_info)}]" if exit_info["code"].to_i != 0 || exit_info["signal"]
        stderr = exit_info["stderr"].to_s.strip
        parts << "\n\npi stderr:\n#{stderr}" unless stderr.empty?
      end
      parts.join(" ").gsub(/ +\n/, "\n")
    end

    # "1" for a normal non-zero exit, "via SIGTERM" when killed by a signal.
    def exit_signal_desc(exit_info)
      exit_info["signal"] ? "via #{exit_info["signal"]}" : exit_info["code"].to_s
    end

    # One display line per tool call. Picks a named key, because the model's key
    # order varies and the first key can be an offset or an edits[] array.
    def tool_call_summary(name, input)
      return "" unless input
      value = input.values_at("path", "pattern", "command").compact.first || input.values.first
      value = "#{value}:#{input["offset"]}" if name == "read" && input["offset"]
      value.to_s[0, 80]
    end

    def log_append(text)
      @ctx.log_file.open("a") { |f| f.puts(text) }
    end
  end
end
