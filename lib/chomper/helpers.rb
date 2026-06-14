require "rainbow"

module Chomper
  module Helpers
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

    # Append a pipe-delimited line to the session progress log.
    def record_progress(id, branch, note)
      @ctx.progress_file.open("a") do |f|
        f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{id}|#{branch}|#{note}"
      end
    end

    # Build the ItemState for a WP, creating its items/<id>/ directory.
    def state_for(item_id, subject, type = nil)
      dir = @ctx.state_dir / "items" / item_id.to_s
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
      st.session_file.exist? && st.session_file.size > 0
    end

    def commit(st)
      worktree.add(all: true)
      diff = worktree.diff("HEAD")
      return if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      worktree.commit("fix: #{st.subject} (WP #{wp_label(st.item_id)})")
      c = worktree.log(1).execute.first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"
      record_progress(st.item_id, st.branch, "committed")
    end

    def generate_pr_description(st, model: Claude::MODEL_WORK)
      return if st.pr_desc_file.exist? && st.pr_desc_file.size > 0
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
