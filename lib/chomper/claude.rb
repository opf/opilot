require "net/http"
require "uri"
require "json"
require "rainbow"

module Chomper
  class Claude
    include Helpers

    TOOLS_READ = "Read"
    TOOLS_IMPL = "Read,Write,Edit,Bash(bin/compose*)"

    def initialize(ctx)
      @ctx = ctx
      @uri = URI(@ctx.claude_url)
    end

    # Runs Claude with the given prompt. Streams tool-use lines to tty, returns text output.
    def run(prompt, tools: nil, fresh: false)
      header = Rainbow("#{log_prefix} CLAUDE CODE PROMPT").bold
      puts header
      log_append(header)
      puts Rainbow(prompt.strip).cyan
      log_append(Rainbow(prompt.strip).cyan)

      resp_header = Rainbow("#{log_prefix} CLAUDE CODE RESPONSE").bold
      puts resp_header
      log_append(resp_header)

      text = http_stream(prompt, tools: tools, fresh: fresh)
      log_append(text)
      puts ""
      text
    end

    # Like run, but also writes ANSI-stripped output to outfile.
    def capture(prompt, tools: nil, outfile:, fresh: false)
      text = run(prompt, tools: tools, fresh: fresh)
      Pathname(outfile).write(strip_ansi(text))
      text
    end

    private

    def http_stream(prompt, tools:, fresh:)
      attempts = 0
      begin
        attempts += 1
        text_parts    = []
        buffer        = "".dup
        at_line_start = true

        req = Net::HTTP::Post.new(@uri)
        req["X-Claude-Tools"] = tools if tools
        req["X-Claude-Fresh"]  = "true" if fresh
        req.body = prompt

        Net::HTTP.start(@uri.host, @uri.port, read_timeout: 600) do |http|
          http.request(req) do |res|
            res.read_body do |chunk|
              buffer << chunk
              while (line = buffer.slice!(/\A[^\n]*\n/))
                parsed = JSON.parse(line.chomp) rescue next
                next unless parsed["type"] == "assistant"
                (parsed.dig("message", "content") || []).each do |part|
                  case part["type"]
                  when "tool_use"
                    $stdout.puts "" unless at_line_start
                    first_val = part["input"]&.values&.first.to_s[0, 80]
                    $stdout.puts Rainbow("  #{part["name"]}  #{first_val}").cyan
                    at_line_start = true
                  when "text"
                    print Rainbow(part["text"]).cyan
                    at_line_start = part["text"].end_with?("\n")
                    text_parts << part["text"]
                  end
                end
              end
            end
          end
        end
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE => e
        if attempts < 3
          delay = attempts * 10
          $stdout.puts Rainbow("\n  ⚠ #{e.class} (attempt #{attempts}) — retrying in #{delay}s…").yellow
          sleep delay
          retry
        end
        raise
      end

      text_parts.join
    end

    def log_append(text)
      @ctx.log_file.open("a") { |f| f.puts(text) }
    end
  end
end
