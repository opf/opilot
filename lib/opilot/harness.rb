require "net/http"
require "uri"
require "json"
require "rainbow"
require "tty-markdown"

module OPilot
  class Harness
    include Helpers

    # The pi run ended with an error result (e.g. it requested a tool that
    # isn't granted, or the run was truncated or aborted). Whatever text was
    # streamed before the failure is partial and must not be treated as a
    # finished answer.
    Error = Class.new(StandardError)

    # Must stay in sync with ALLOWED_TOOL_GRANTS in server.js, which refuses
    # any other grant. pi's tool names are lowercase; there's no glob tool, so
    # `find` covers that job. Grep/find/ls are granted everywhere: without them
    # the model has no way to search the repo and reaches for Bash find/grep
    # instead, which is denied and kills the run. Bash is granted so pi can
    # browse git history (log/show/blame/diff) across the repos for context;
    # the pi-guards.ts tool_call hook confines it to read-only git — no commit,
    # push, remote, or non-git command — and the egress proxy blocks exfiltration.
    TOOLS_READ = "read,grep,find,ls,bash"
    TOOLS_IMPL = "read,grep,find,ls,bash,write,edit"

    # Models, pinned so behaviour doesn't drift when the catalog's default
    # changes. Values are OpenRouter slugs behind pi's provider prefix
    # (openrouter/<vendor>/<model>), not bare Anthropic API ids — a bare id
    # (e.g. "claude-opus-4-8") is not a valid slug and must be corrected in
    # any existing .env. A WP's heavy model is shared by every session-bound phase
    # (chat, plan, review, implement) — they resume one per-WP session, and
    # switching models mid-session would discard the cache and resumed context.
    # MODEL_LIGHT is for stateless one-shot passes where a cheaper model
    # suffices (e.g. crafting a gh-agent commit subject, or a PR description).
    # server.js validates the value by format, not an allowlist — model choice
    # grants no privilege (unlike the tool grants above).
    MODEL_HEAVY  = ENV.fetch("OPILOT_MODEL_HEAVY", "openrouter/anthropic/claude-opus-4.8")
    MODEL_LIGHT  = ENV.fetch("OPILOT_MODEL_LIGHT", "openrouter/anthropic/claude-haiku-4.5")

    def initialize(ctx)
      @ctx = ctx
      @uri = URI(@ctx.harness_url)
    end

    # Is the harness container up and serving? Cheap GET against server.js's
    # health endpoint — the same one compose's healthcheck uses.
    def available?
      Net::HTTP.start(@uri.host, @uri.port, open_timeout: 2, read_timeout: 2) do |http|
        http.get("/health").is_a?(Net::HTTPSuccess)
      end
    rescue StandardError
      false
    end

    # Fail fast, before a command does any real work, when the container isn't
    # there. Without this the first prompt spends ~30s in http_stream's
    # reconnect backoff and then surfaces a bare SocketError — long after the
    # branch has been checked out and the spec tree materialised.
    def ensure_available!
      return if available?
      raise OPilot::FatalError, <<~MSG.strip
        The harness container is not reachable at #{@ctx.harness_url}.
        Start it with `docker compose up -d --wait harness`, or run this through
        ./opilot (which starts it for the commands that need it).
      MSG
    end

    # Runs the LLM with the given prompt. Streams tool-use lines to tty, returns text output.
    # Pass session_file: (a Pathname) to enable per-WP session continuity — the file is
    # read for the session ID before the call and updated with the new ID after.
    def run(prompt, tools: nil, model: MODEL_HEAVY, session_file: nil)
      session_id = session_file&.exist? ? session_file.read.strip : nil

      header = Rainbow("#{log_prefix} PI PROMPT (model: #{model}, session: #{session_id || "fresh"})").bold
      puts header
      log_append(header)
      puts Rainbow(prompt.strip).cyan
      log_append(Rainbow(prompt.strip).cyan)

      resp_header = Rainbow("#{log_prefix} PI RESPONSE").bold
      puts resp_header
      log_append(resp_header)

      text, new_session_id, error = http_stream(prompt, tools: tools, model: model, session_id: session_id)

      # A resumed session the CLI no longer has (e.g. the harness container was
      # recreated/killed before the transcript was durably written) makes
      # --resume fail immediately, and the dead id would poison this WP forever —
      # every later call reads the same id and fails identically. Recover once by
      # retrying as a fresh session: we lose the prior conversation context, but
      # the prompts reference the item/plan files on disk, so it can re-orient.
      if error && session_id && lost_session?(error)
        log_append("session #{session_id} is gone — retrying fresh")
        $stdout.puts Rainbow("  ⚠ session #{session_id} not found — starting fresh").yellow
        text, new_session_id, error = http_stream(prompt, tools: tools, model: model, session_id: nil)
      end

      # Save the session even on error, so a retry can resume with context.
      if session_file && new_session_id
        log_append("session: captured #{new_session_id} → #{session_file}")
        session_file.write(new_session_id)
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
    def capture(prompt, tools: nil, model: MODEL_HEAVY, outfile:, session_file: nil)
      text = run(prompt, tools: tools, model: model, session_file: session_file)
      Pathname(outfile).write(strip_ansi(text))
      text
    end

    private

    def http_stream(prompt, tools:, model:, session_id: nil)
      attempts = 0
      begin
        attempts += 1
        text_parts          = []
        buffer              = "".dup
        at_line_start       = true
        after_tool          = false
        captured_session_id = nil
        final_result        = nil
        error               = nil
        error_subtype       = nil
        exit_info           = nil

        req = Net::HTTP::Post.new(@uri)
        req["X-Harness-Tools"]   = tools      if tools
        req["X-Harness-Model"]   = model      if model
        req["X-Harness-Session"] = session_id if session_id
        req.body = prompt

        Net::HTTP.start(@uri.host, @uri.port, read_timeout: 600) do |http|
          http.request(req) do |res|
            unless res.is_a?(Net::HTTPSuccess)
              # e.g. 403 "unknown tool grant" when the harness image predates a
              # grant change — surface the body instead of streaming nothing.
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
                  captured_session_id = parsed["session_id"]
                when "exit"
                  # server.js's final diagnostic: exit code/signal + stderr tail.
                  exit_info = parsed
                when "result"
                  # The CLI's final verdict on the run. An error here (denied
                  # tool, max turns, …) means the run died mid-way; surface it
                  # instead of passing the partial text off as the answer.
                  if parsed["is_error"] || parsed["subtype"].to_s.start_with?("error")
                    error_subtype = parsed["subtype"].to_s
                    error = parsed["result"].to_s.strip
                    error = error_subtype if error.empty?
                    $stdout.puts "" unless at_line_start
                    $stdout.puts Rainbow("  ✗ #{error}").red
                    at_line_start = true
                  else
                    # The CLI's final answer — just the last message, not the
                    # per-turn reasoning streamed along the way. Prefer it as the
                    # return value so callers (PR comments, plan.md, …) get the
                    # conclusion, not the narration.
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
                    when "text"
                      if after_tool && !text_parts.empty? && !text_parts.last.end_with?("\n")
                        text_parts << "\n\n"
                      end
                      after_tool    = false
                      # Display the rendered Markdown; keep the raw text for the
                      # return value, the log, and capture's outfile.
                      shown = render_markdown(part["text"])
                      print shown
                      at_line_start = shown.end_with?("\n")
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

      # Fall back to the streamed parts only if the run somehow ended without a
      # final result (e.g. a transport cut-off before the result event).
      text = final_result.to_s.strip.empty? ? text_parts.join : final_result

      # The CLI may end with a non-zero exit and no result event at all (a hard
      # crash) — treat that as an error too, so the caller doesn't pass empty
      # text off as a finished answer.
      if !error && exit_info && exit_info["timed_out"]
        error = "pi run timed out and was killed"
      elsif !error && exit_info && exit_info["code"].to_i != 0 && text.to_s.strip.empty?
        error = "pi exited #{exit_signal_desc(exit_info)} with no result"
      end

      # Enrich an error with the real cause from the CLI's stderr tail. For the
      # `error_during_execution` subtype the result text is empty (we fell back to
      # the bare subtype), so stderr is the only place the actual reason — an API
      # overload, internal crash, hook failure — is written.
      error = decorate_error(error, error_subtype, exit_info) if error

      [text, captured_session_id, error]
    end

    # Combine the CLI's error message with the diagnostic detail server.js
    # forwards: the result subtype (so a bare "error_during_execution" is at least
    # labelled), the exit code/signal, and a tail of the CLI's stderr (the only
    # place the underlying cause is written for an execution error). Kept compact
    # so it still reads as a single comment/log line.
    def decorate_error(error, subtype, exit_info)
      parts = [error]
      # Add the error subtype when it carries info the message doesn't already.
      parts << "(#{subtype})" if subtype.to_s.start_with?("error") && error != subtype
      if exit_info
        parts << "[exit #{exit_signal_desc(exit_info)}]" if exit_info["code"].to_i != 0 || exit_info["signal"]
        stderr = exit_info["stderr"].to_s.strip
        parts << "\n\npi stderr:\n#{stderr}" unless stderr.empty?
      end
      parts.join(" ").gsub(/ +\n/, "\n")
    end

    # pi's message when --session points at a session it can't find (verified
    # against pi 0.84.2: "No session found matching '<id>'", printed to stderr
    # with no JSON output at all and exit 1). Detected via the stderr tail
    # server.js forwards on the exit event.
    def lost_session?(error)
      error.to_s.match?(/No session found matching/i)
    end

    # "1" for a normal non-zero exit, "via SIGTERM" when killed by a signal.
    def exit_signal_desc(exit_info)
      exit_info["signal"] ? "via #{exit_info["signal"]}" : exit_info["code"].to_s
    end

    # A one-line summary of a tool call for the streamed progress display —
    # this only affects what's printed/logged, never what pi actually does.
    # pi's tool schemas (verified against 0.84.2) all declare "path" (read,
    # write, edit, ls, find, grep), "pattern" (grep, find) or "command" (bash)
    # among their args, but the model's JSON key order doesn't reliably follow
    # the schema's declared order — a continuation read re-emits offset before
    # path, an edit re-emits its edits[] array before path. Picking a named key
    # instead of "whichever key came first" avoids showing a bare offset
    # number, or a raw array-of-hashes dump, in place of the file path.
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
