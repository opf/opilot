require "net/http"
require "uri"
require "json"
require "rainbow"

module Chomper
  class Claude
    include Helpers

    # Must stay in sync with ALLOWED_TOOL_GRANTS in server.js, which refuses
    # any other grant. The Bash rule needs both forms: the bare command and the
    # space-separated prefix — "bin/compose*" (no space) would also match
    # unrelated commands like "bin/composer-evil".
    TOOLS_READ = "Read"
    TOOLS_IMPL = "Read,Write,Edit,Bash(bin/compose),Bash(bin/compose *)"

    def initialize(ctx)
      @ctx = ctx
      @uri = URI(@ctx.claude_url)
    end

    # Runs Claude with the given prompt. Streams tool-use lines to tty, returns text output.
    # Pass session_file: (a Pathname) to enable per-WP session continuity — the file is
    # read for the session ID before the call and updated with the new ID after.
    def run(prompt, tools: nil, session_file: nil)
      session_id = session_file&.exist? ? session_file.read.strip : nil

      header = Rainbow("#{log_prefix} CLAUDE CODE PROMPT (session: #{session_id || "fresh"})").bold
      puts header
      log_append(header)
      puts Rainbow(prompt.strip).cyan
      log_append(Rainbow(prompt.strip).cyan)

      resp_header = Rainbow("#{log_prefix} CLAUDE CODE RESPONSE").bold
      puts resp_header
      log_append(resp_header)

      text, new_session_id = http_stream(prompt, tools: tools, session_id: session_id)
      if session_file && new_session_id
        log_append("session: captured #{new_session_id} → #{session_file}")
        session_file.write(new_session_id)
      end
      log_append(text)
      puts ""
      text
    end

    # Like run, but also writes ANSI-stripped output to outfile.
    def capture(prompt, tools: nil, outfile:, session_file: nil)
      text = run(prompt, tools: tools, session_file: session_file)
      Pathname(outfile).write(strip_ansi(text))
      text
    end

    private

    def http_stream(prompt, tools:, session_id: nil)
      attempts = 0
      begin
        attempts += 1
        text_parts          = []
        buffer              = "".dup
        at_line_start       = true
        after_tool          = false
        captured_session_id = nil

        req = Net::HTTP::Post.new(@uri)
        req["X-Claude-Tools"]   = tools      if tools
        req["X-Claude-Session"] = session_id if session_id
        req.body = prompt

        Net::HTTP.start(@uri.host, @uri.port, read_timeout: 600) do |http|
          http.request(req) do |res|
            res.read_body do |chunk|
              buffer << chunk
              while (line = buffer.slice!(/\A[^\n]*\n/))
                parsed = JSON.parse(line.chomp) rescue next
                case parsed["type"]
                when "session_id"
                  captured_session_id = parsed["session_id"]
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

      [text_parts.join, captured_session_id]
    end

    def log_append(text)
      @ctx.log_file.open("a") { |f| f.puts(text) }
    end
  end
end
