require "rainbow"

module Chomper
  module Helpers
    def log_script(msg)
      ts = Time.now.strftime("%H:%M:%S")
      msg.each_line do |line|
        formatted = Rainbow("[ #{ts} ] #{line.chomp}").bold
        @ctx.log_file.open("a") { |f| f.puts(formatted) }
        $stdout.puts(formatted)
      end
      $stdout.print(Rainbow("").gray) # set gray for subsequent docker output
      $stdout.flush
    end

    def strip_ansi(str)
      Rainbow.uncolor(str)
    end

    def safe_rm(*paths)
      paths.each do |path|
        path = Pathname(path)
        unless path.to_s.start_with?(@ctx.script_dir.to_s)
          $stderr.puts "BUG: safe_rm refusing unexpected path: #{path}"
          next
        end
        path.delete if path.exist?
      end
    end

    def branch_slug(id, title)
      slug = title.downcase.gsub(/[^a-z0-9]/, "-")[0, 40]
      "fix/#{id.to_i}-#{slug}"
    end

    # Uses revparse instead of branches.local, which parses `git branch -a` and
    # chokes on "* (no branch)" (detached HEAD) and "+" (branch in a linked worktree).
    def local_branch_exists?(git_repo, branch)
      git_repo.revparse("refs/heads/#{branch}")
      true
    rescue Git::FailedError
      false
    end
  end
end
