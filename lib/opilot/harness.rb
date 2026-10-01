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
    # push, remote, or non-git command (and no writes into any .git/, which
    # would turn those read-only subcommands into code execution). The harness
    # has no network egress but inference-gw, so there is nowhere to exfiltrate to.
    # The ONE exception is `git rm` / `git clean`, which pi-guards.ts unlocks
    # when the grant carries write/edit — pi ships no delete tool, so bash is
    # the only place one can live, and keying it to this grant is what keeps
    # TOOLS_READ genuinely read-only.
    TOOLS_READ = "read,grep,find,ls,bash"
    TOOLS_IMPL = "read,grep,find,ls,bash,write,edit"

    # The op_query variants, granted only to the roles marked
    # `mcp` (roles.rb). Must stay in sync with ALLOWED_TOOL_GRANTS in server.js.
    TOOLS_READ_OP = "#{TOOLS_READ},op_query"
    TOOLS_IMPL_OP = "#{TOOLS_IMPL},op_query"

    # Builds one grant from the base plus whichever MCP tools are switched on.
    # The array literal IS the canonical order — server.js's ALLOWED_TOOL_GRANTS
    # holds the same eight strings as exact literals, and an order that differed
    # between the two would be a 403 the model cannot explain. One place to look,
    # rather than eight named constants here and eight there.
    def self.tools_for(base, op_mcp:, gh_mcp:)
      [base, ("op_query" if op_mcp), ("gh_query" if gh_mcp)].compact.join(",")
    end

    # Models, pinned so behaviour doesn't drift when the catalog's default
    # changes. Values carry pi's provider prefix — openrouter/<vendor>/<model>,
    # or <provider>/<model-id> for a self-hosted one ("local/qwen2.5-coder:32b").
    # A bare id ("claude-opus-4-8") is not a valid slug.
    #
    # THE PREFIX IS LOAD-BEARING beyond naming: server.js reads it to decide
    # whether to hand pi the provider config committed in pi-models.json or to
    # generate one for the configured upstream. It is the only signal for that,
    # deliberately — a second "mode" variable could disagree with the slug.
    #
    # MODEL_HEAVY is shared by every session-bound phase (chat, plan, review,
    # implement): they resume one per-WP session, and switching models mid-session
    # would discard the cache and resumed context. MODEL_LIGHT is for stateless
    # one-shot passes. server.js validates the value by format, not an allowlist —
    # model choice grants no privilege (unlike the tool grants above).
    MODEL_HEAVY  = ENV.fetch("OPILOT_MODEL_HEAVY", "openrouter/anthropic/claude-sonnet-5.5")
    MODEL_LIGHT  = ENV.fetch("OPILOT_MODEL_LIGHT", "openrouter/anthropic/claude-haiku-4.5")

    # How long to wait on a silent socket. This must be the OUTER of the two
    # bounds — server.js kills the run and reports an `exit` frame naming the
    # real cause; giving up first turns that into a bare Net::ReadTimeout.
    #
    # The harness writes NOTHING until a run starts, and it runs one call at a
    # time, so a queued request sees a silent socket for the whole run ahead of
    # it. The bound must therefore cover the server's ceiling plus one full idle
    # window. Both knobs read the same env vars server.js reads, so raising the
    # ceiling cannot leave this behind.
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
    # Pass session_file: (a Pathname) to enable per-WP session continuity. The runner
    # owns the id: it reuses the file's, or mints one, and pi's --session-id opens
    # that session or creates it when absent — so a lost session simply starts fresh.
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
                  started = true
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
                    when "text_delta", "thinking_delta"
                      # Printed raw (no Markdown rendering) as it streams in, so a
                      # long-running block — e.g. a reasoning model's "thinking"
                      # text — is visible instead of leaving the terminal silent
                      # until text_end/thinking_end or a length-cap error. Not
                      # accumulated into text_parts: "text" below carries the
                      # block's full, authoritative content once it completes.
                      chunk = part["text"].to_s
                      next if chunk.empty?
                      print(part["type"] == "thinking_delta" ? Rainbow(chunk).gray : chunk)
                      at_line_start = chunk.end_with?("\n")
                    when "text"
                      if after_tool && !text_parts.empty? && !text_parts.last.end_with?("\n")
                        text_parts << "\n\n"
                      end
                      after_tool = false
                      # Already shown live via text_delta above; keep the raw text
                      # for the return value, the log, and capture's outfile.
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
        # server.js bounds a run twice (see its PROC_IDLE_TIMEOUT_MS comment):
        # "idle" is a wedged run, "max" a run that stayed busy past the ceiling.
        # They call for different answers — retry vs. a smaller ask — so name
        # which one fired. A harness image predating timeout_kind sends none.
        error = case exit_info["timeout_kind"]
                when "idle" then "pi run stalled with no output and was killed"
                when "max"  then "pi run hit the maximum run time and was killed"
                else "pi run timed out and was killed"
                end
      elsif !error && exit_info && exit_info["code"].to_i != 0 && text.to_s.strip.empty?
        error = "pi exited #{exit_signal_desc(exit_info)} with no result"
      end

      # Enrich an error with the real cause from the CLI's stderr tail. For the
      # `error_during_execution` subtype the result text is empty (we fell back to
      # the bare subtype), so stderr is the only place the actual reason — an API
      # overload, internal crash, hook failure — is written.
      error = decorate_error(error, error_subtype, exit_info) if error

      [text, started, error]
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
