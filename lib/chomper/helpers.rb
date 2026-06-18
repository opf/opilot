require "json"
require "tempfile"
require "time"
require "rainbow"
require "tty-markdown"

module Chomper
  module Helpers
    # File/JSON idioms shared across classes that don't all `include Helpers`
    # (Pull, UI), so they're module functions like .wp_label below.

    # Per-WP state lives under .chomper/items/<id>/ — one source of truth for
    # that path, used everywhere instead of re-joining the literal.
    def self.items_dir(ctx)
      ctx.state_dir / "items"
    end

    def self.item_dir(ctx, id)
      items_dir(ctx) / id.to_s
    end

    # A file exists and is non-empty — the "has real content" check used for
    # plans, PR descriptions, session ids, and shipped markers.
    def self.file_has_content?(path)
      path.exist? && path.size > 0
    end

    # Parse a JSON file, returning nil on any read/parse error. Callers add
    # their own `|| {}` / `|| []` fallback where they depend on one.
    def self.safe_json_read(path)
      JSON.parse(path.read)
    rescue StandardError
      nil
    end

    # Write JSON to `path` atomically (tempfile in the same dir, then rename),
    # so a crash mid-write never leaves a half-written cache. `name` is the
    # tempfile prefix.
    def self.write_json_atomic(path, data, name)
      tmp = Tempfile.new(name, path.dirname)
      tmp.write(JSON.generate(data))
      tmp.close
      File.rename(tmp.path, path.to_s)
    rescue StandardError
      tmp&.unlink
      raise
    end

    # Turn a "how far back" answer into an ISO8601 cutoff. Accepts a relative
    # span ("1h", "2 days", "1 week"), an absolute time, or blank/"now" (= now).
    # Shared by the OpenProject agent (Pull) and the GitHub agent (GhPull) so the
    # "scan from" prompt parses identically in both.
    def self.parse_scan_from(input)
      input = input.to_s.strip.downcase
      return Time.now.utc.iso8601 if input.empty? || input == "now"
      if (m = input.match(/\A(\d+)\s*(m(?:in(?:ute)?s?)?|h(?:our)?s?|d(?:ay)?s?|w(?:eek)?s?)\z/))
        n = m[1].to_i
        seconds = case m[2][0]
                  when "m" then n * 60
                  when "h" then n * 3600
                  when "d" then n * 86400
                  when "w" then n * 604800
                  end
        return (Time.now - seconds).utc.iso8601
      end
      begin
        Time.parse(input).utc.iso8601
      rescue ArgumentError
        puts "  Could not parse '#{input}' — defaulting to now"
        Time.now.utc.iso8601
      end
    end

    # Per-WP working state: just the paths under items/<id>/ plus the branch.
    # Shared by both runners (agent and backlog) via #state_for below.
    ItemState = Struct.new(:item_id, :subject, :branch, :item_dir, :plan_file,
                           :item_file, :review_file, :pr_desc_file, :pr_url_file,
                           :session_file, keyword_init: true)

    # A work package id as the user types it: numeric ("59942") or semantic
    # ("PROJ-123", instances in semantic-identifier mode). Mirrors OpenProject's
    # WorkPackage::SemanticIdentifier::ID_ROUTE_CONSTRAINT.
    WP_ID_PATTERN = /\A(?:\d+|[A-Z][A-Z0-9_]*-\d+)\z/

    # Single source of truth for log-line timestamps — both the time format and
    # the bracket wrapping — so every line chomper writes shares one format.
    LOG_TIME_FORMAT = "%H:%M:%S"

    # Render Markdown as ANSI for the terminal — used both for Claude's streamed
    # text and for re-displaying saved plans from disk, so they look the same.
    # Skipped when stdout isn't a tty (piped, captured by tests, redirected) or
    # when CHOMPER_MARKDOWN is off; then the raw, cyan-tinted text is shown.
    # Falls back to the raw text if rendering raises (e.g. a partial fence).
    def render_markdown(text)
      return Rainbow(text).cyan unless $stdout.tty? && markdown_enabled?
      TTY::Markdown.parse(text)
    rescue StandardError
      Rainbow(text).cyan
    end

    def markdown_enabled?
      !%w[0 false no off].include?(ENV["CHOMPER_MARKDOWN"].to_s.strip.downcase)
    end

    def log_timestamp
      Time.now.strftime(LOG_TIME_FORMAT)
    end

    # The bracketed prefix every log line starts with, e.g. "[ 14:23:01 ]".
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

    # Inline label for a work package id, mirroring OpenProject's
    # WorkPackage::SemanticIdentifier.format_display_id: semantic ids are
    # self-describing ("PROJ-42"); classic numeric ids keep the "#42" prefix.
    def self.wp_label(id)
      id.to_s.match?(/[A-Za-z]/) ? id.to_s : "##{id}"
    end

    def wp_label(id)
      Helpers.wp_label(id)
    end

    # Shared by the commit subject and the PR title so the two stay identical.
    def self.pr_title(id, subject)
      "[#{wp_label(id)}] #{subject}"
    end

    def pr_title(id, subject)
      Helpers.pr_title(id, subject)
    end

    # Calls the user back for an input prompt that typically follows a long
    # unattended Claude run. OSC 9 posts a desktop notification in terminals
    # that support it (Ghostty, iTerm2, WezTerm, kitty); others drop the
    # sequence. The BEL after it rings the bell everywhere else (sound, dock
    # bounce, tab highlight — whatever the emulator is configured to do).
    def ping_terminal(message = "chomper is waiting for your input")
      $stdout.print("\e]9;#{message}\e\\\a")
      $stdout.flush
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

    def branch_slug(id, type, title)
      prefix = sanitize_branch_part(type).then { |s| s.empty? ? "task" : s }
      slug   = sanitize_branch_part(title)[0, 40]
      "#{prefix}/#{id}-#{slug}"
    end

    private

    def sanitize_branch_part(str)
      str.downcase.gsub("&", "and").gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    # Uses revparse instead of branches.local, which parses `git branch -a` and
    # chokes on "* (no branch)" (detached HEAD) and "+" (branch in a linked worktree).
    def local_branch_exists?(git_repo, branch)
      git_repo.revparse("refs/heads/#{branch}")
      true
    rescue Git::FailedError
      false
    end

    # Git handle on the isolated worktree where fixes are made.
    def worktree
      @worktree ||= Git.open(@ctx.worktree_host.to_s)
    end

    # Check out the WP's fix branch, creating it from origin/dev on first use.
    # `checkout -b` from a remote start point makes the new branch track
    # origin/dev, which is dangerous: a bare `git pull` merges dev into the
    # fix branch, and with push.default=upstream a bare `git push` targets dev
    # itself. Re-point tracking at the branch's own name — the PR branch it is
    # pushed to — on every checkout, which also repairs branches created
    # before this fix.
    def checkout_branch(st)
      if local_branch_exists?(worktree, st.branch)
        worktree.checkout(st.branch)
      else
        worktree.checkout(st.branch, new_branch: true, start_point: "origin/dev")
      end
      worktree.config("branch.#{st.branch}.remote", "origin")
      worktree.config("branch.#{st.branch}.merge", "refs/heads/#{st.branch}")
    end

    # Check out an existing PR's branch and sync it to the PR's current head.
    # Unlike #checkout_branch (which starts new work from origin/dev), gh-agent
    # acts on a branch that already lives on the remote. The caller must first
    # fetch that head into FETCH_HEAD over HTTPS (Clients::GitHub#fetch_branch) —
    # we then hard-reset onto FETCH_HEAD, building on the latest PR head and
    # never diverging. We reset to FETCH_HEAD rather than a remote-tracking ref
    # so this works without relying on the worktree's `origin` (which may be SSH
    # and unreachable in the container).
    def checkout_pr_branch(branch)
      if local_branch_exists?(worktree, branch)
        worktree.checkout(branch)
        worktree.reset_hard("FETCH_HEAD")
      else
        worktree.checkout(branch, new_branch: true, start_point: "FETCH_HEAD")
      end
    end

    # Append a pipe-delimited line to the session progress log.
    def record_progress(id, branch, note)
      @ctx.progress_file.open("a") do |f|
        f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{id}|#{branch}|#{note}"
      end
    end

    # Build the ItemState for a WP, creating its items/<id>/ directory.
    def state_for(item_id, subject, type = nil)
      dir = Helpers.item_dir(@ctx, item_id)
      dir.mkpath
      ItemState.new(
        item_id:      item_id.to_s,
        subject:      subject.to_s,
        branch:       branch_slug(item_id, type.to_s, subject.to_s),
        item_dir:     dir,
        plan_file:    dir / "plan.md",
        item_file:    dir / "item.json",
        review_file:  dir / "review.txt",
        pr_desc_file: dir / "pr.md",
        pr_url_file:  dir / "pr_url.txt",
        session_file: dir / "session_id"
      )
    end

    # Rewrite a host path under .chomper/ to its path inside the Claude container.
    def container_path(host_path)
      host_path.to_s.sub(@ctx.state_dir.to_s, @ctx.state_container)
    end

    def branch_has_commits?(st)
      worktree.log.between("origin/dev", st.branch).execute.any?
    end

    # True when a phase will resume an existing per-WP session (so the plan and
    # issue are already in context). False for a fresh session — e.g. the first
    # call, or after the session was cleared — where the prompt must tell Claude
    # to read the plan instead of assuming it.
    def session_resumable?(st)
      Helpers.file_has_content?(st.session_file)
    end

    def commit(st)
      worktree.add(all: true)
      diff = worktree.diff("HEAD")
      return if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      worktree.commit(pr_title(st.item_id, st.subject))
      c = worktree.log(1).execute.first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"
      record_progress(st.item_id, st.branch, "committed")
    end

    def generate_pr_description(st, model: Claude::MODEL_WORK)
      return if Helpers.file_has_content?(st.pr_desc_file)
      template_file    = @ctx.repo_path / ".github" / "pull_request_template.md"
      template_section = template_file.exist? ? "Fill in this PR template exactly: #{template_file}" : ""
      diff_stat = worktree.diff("HEAD~1", "HEAD").stats[:files]
        .map { |f, s| "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        .join("\n")
      prompt = Prompts.pr_description(
        item: container_path(st.item_file), plan: container_path(st.plan_file),
        diff_stat: diff_stat, template_section: template_section
      )
      pr_text = @claude.run(prompt, tools: Claude::TOOLS_READ, model: model, session_file: st.session_file)
      pr_body = pr_text[/^#.*/m] || pr_text
      st.pr_desc_file.write(strip_ansi(pr_body))
    end
  end
end
