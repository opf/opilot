require "net/http"
require "uri"
require "json"
require "rainbow"

module Chomper
  class Claude
    include Helpers

    # The claude CLI run ended with an error result (e.g. it requested a tool
    # that isn't granted, or hit max turns). Whatever text was streamed before
    # the failure is partial and must not be treated as a finished answer.
    Error = Class.new(StandardError)

    # Must stay in sync with ALLOWED_TOOL_GRANTS in server.js, which refuses
    # any other grant. Grep and Glob are granted everywhere: without them the
    # model has no way to search the repo and reaches for Bash find/grep
    # instead, which is denied and kills the run. The Bash rule needs both
    # forms: the bare command and the space-separated prefix — "bin/compose*"
    # (no space) would also match unrelated commands like "bin/composer-evil".
    TOOLS_READ = "Read,Grep,Glob"
    TOOLS_IMPL = "Read,Grep,Glob,Write,Edit,Bash(bin/compose),Bash(bin/compose *)"

    # Models, pinned so behaviour doesn't drift when the CLI's default changes.
    # A WP's work model is shared by every session-bound phase (chat, plan,
    # review, implement, PR description) — they resume one per-WP session, and
    # switching models mid-session would discard the cache and resumed context.
    # MODEL_WORK is the default; backlog mode downgrades trivial/simple items to
    # MODEL_SIMPLE (chosen once per WP via .model_for, so it stays constant across
    # the session). MODEL_FAST is for triage only: a stateless classification pass
    # where a cheaper model suffices. server.js validates the value by format, not
    # an allowlist — model choice grants no privilege (unlike the tool grants above).
    MODEL_WORK   = ENV.fetch("CHOMPER_MODEL", "claude-opus-4-8")
    MODEL_SIMPLE = ENV.fetch("CHOMPER_SIMPLE_MODEL", "claude-sonnet-4-6")
    MODEL_FAST   = ENV.fetch("CHOMPER_TRIAGE_MODEL", "claude-haiku-4-5")

    # Pick the work model for a WP from its triage complexity. Trivial and simple
    # fixes don't need the top model. Unknown/nil complexity → MODEL_WORK.
    def self.model_for(complexity)
      %w[trivial simple].include?(complexity.to_s.downcase) ? MODEL_SIMPLE : MODEL_WORK
    end

    def initialize(ctx)
      @ctx = ctx
      @uri = URI(@ctx.claude_url)
    end

    # Runs Claude with the given prompt. Streams tool-use lines to tty, returns text output.
    # Pass session_file: (a Pathname) to enable per-WP session continuity — the file is
    # read for the session ID before the call and updated with the new ID after.
    def run(prompt, tools: nil, model: MODEL_WORK, session_file: nil)
      session_id = session_file&.exist? ? session_file.read.strip : nil

      header = Rainbow("#{log_prefix} CLAUDE CODE PROMPT (model: #{model}, session: #{session_id || "fresh"})").bold
      puts header
      log_append(header)
      puts Rainbow(prompt.strip).cyan
      log_append(Rainbow(prompt.strip).cyan)

      resp_header = Rainbow("#{log_prefix} CLAUDE CODE RESPONSE").bold
      puts resp_header
      log_append(resp_header)

      text, new_session_id, error = http_stream(prompt, tools: tools, model: model, session_id: session_id)
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
    def capture(prompt, tools: nil, model: MODEL_WORK, outfile:, session_file: nil)
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
        error               = nil

        req = Net::HTTP::Post.new(@uri)
        req["X-Claude-Tools"]   = tools      if tools
        req["X-Claude-Model"]   = model      if model
        req["X-Claude-Session"] = session_id if session_id
        req.body = prompt

        Net::HTTP.start(@uri.host, @uri.port, read_timeout: 600) do |http|
          http.request(req) do |res|
            unless res.is_a?(Net::HTTPSuccess)
              # e.g. 403 "unknown tool grant" when the claude image predates a
              # grant change — surface the body instead of streaming nothing.
              error = "claude server HTTP #{res.code}: #{res.body.to_s.strip}"
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
                when "result"
                  # The CLI's final verdict on the run. An error here (denied
                  # tool, max turns, …) means the run died mid-way; surface it
                  # instead of passing the partial text off as the answer.
                  if parsed["is_error"] || parsed["subtype"].to_s.start_with?("error")
                    error = parsed["result"].to_s.strip
                    error = parsed["subtype"].to_s if error.empty?
                    $stdout.puts "" unless at_line_start
                    $stdout.puts Rainbow("  ✗ #{error}").red
                    at_line_start = true
                  end
                when "assistant"
                  (parsed.dig("message", "content") || []).each do |part|
                    case part["type"]
                    when "tool_use"
                      $stdout.puts "" unless at_line_start
                      first_val = part["input"]&.values&.first.to_s[0, 80]
                      $stdout.puts Rainbow("  #{part["name"]}  #{first_val}").cyan
                      at_line_start = true
                      after_tool    = true
                    when "text"
                      if after_tool && !text_parts.empty? && !text_parts.last.end_with?("\n")
                        text_parts << "\n\n"
                      end
                      after_tool    = false
                      print Rainbow(part["text"]).cyan
                      at_line_start = part["text"].end_with?("\n")
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

      [text_parts.join, captured_session_id, error]
    end

    def log_append(text)
      @ctx.log_file.open("a") { |f| f.puts(text) }
    end
  end
end
