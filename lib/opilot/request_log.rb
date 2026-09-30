module OPilot
  # One line per API request or git network command, to the terminal and
  # chomp.log. Silent until CLI#session sets `file`, so tests print nothing.
  module RequestLog
    class << self
      attr_accessor :file

      def log(msg)
        return unless file
        line = "[ #{Time.now.strftime(Helpers::LOG_TIME_FORMAT)} ] #{msg}"
        file.open("a") { |f| f.puts(line) }
        $stdout.puts(Rainbow(line).gray)
      rescue StandardError
        nil # a log line must never fail the request
      end
    end
  end
end
