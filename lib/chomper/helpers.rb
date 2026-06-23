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

    # Set the process git identity (author + committer) to the GitHub bot
    # account the token belongs to, so commits are attributed to the bot and the
    # operator's email never lands on a public PR. Runs once per process; a no-op
    # when no token is set (planning-only). Falls back silently to the host
    # identity ./chomper exported if the lookup fails.
    def self.adopt_github_author!(ctx)
      return if @github_author_adopted
      return unless ctx.respond_to?(:github_token) && ctx.github_token
      name, email = Clients::GitHub.new(ctx.github_token).author_identity
      ENV["GIT_AUTHOR_NAME"]  = ENV["GIT_COMMITTER_NAME"]  = name
      ENV["GIT_AUTHOR_EMAIL"] = ENV["GIT_COMMITTER_EMAIL"] = email
      @github_author_adopted = true
    rescue StandardError => e
      warn "  Warning: couldn't resolve bot git identity (#{e.message}); using host git identity"
    end

    # Turn a "how far back" answer into an ISO8601 cutoff. Accepts a relative
    # span ("1h", "2 days", "1 week", "1 month", "1 year"), an absolute time, or
    # blank/"now" (= now). Months and years use 30- and 365-day approximations,
    # which is plenty for a scan floor. Shared by the OpenProject agent (Pull)
    # and the GitHub agent (GhPull) so the "scan from" prompt parses identically.
    def self.parse_scan_from(input)
      input = input.to_s.strip.downcase
      return Time.now.utc.iso8601 if input.empty? || input == "now"
      if (m = input.match(/\A(\d+)\s*([a-z]+)\z/))
        n = m[1].to_i
        # Classify on the whole unit, not the first letter: "m" is minutes but
        # "mo"/"month" is months, so a first-char test can't tell them apart.
        seconds = case m[2]
                  when "m", /\Amin(ute)?s?\z/   then n * 60
                  when /\Ah(our)?s?\z/           then n * 3600
                  when /\Ad(ay)?s?\z/            then n * 86400
                  when /\Aw(eek)?s?\z/           then n * 604800
                  when /\Amo(n(th)?)?s?\z/       then n * 2592000
                  when /\Ay(ear)?s?\z/           then n * 31536000
                  end
        return (Time.now - seconds).utc.iso8601 if seconds
      end
      begin
        Time.parse(input).utc.iso8601
      rescue ArgumentError
        puts "  Could not parse '#{input}' — defaulting to now"
        Time.now.utc.iso8601
      end
    end

    # Per-WP working state: the shared paths under items/<id>/ plus the branch and
    # the chosen target repos. PR-scoped artifacts (pr.md, pr_url.txt, gh caches)
    # live under items/<id>/repos/<name>/ since a WP may ship to several repos —
    # resolve them with the per-repo helpers below. Shared by both runners (agent
    # and backlog) via #state_for.
    ItemState = Struct.new(:item_id, :subject, :branch, :repos, :item_dir, :plan_file,
                           :item_file, :related_file, :review_file, :target_repos_file,
                           :session_file, keyword_init: true) do
      # Per-repo artifact directory (items/<id>/repos/<name>/), created on demand.
      def repo_dir(repo)
        dir = item_dir / "repos" / repo_name(repo)
        dir.mkpath
        dir
      end

      def pr_desc_file(repo); repo_dir(repo) / "pr.md"; end
      def pr_url_file(repo);  repo_dir(repo) / "pr_url.txt"; end

      private

      def repo_name(repo)
        repo.respond_to?(:name) ? repo.name : repo.to_s
      end
    end

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

    # Git handle on a repo's isolated worktree, memoized per repo so a WP that
    # spans several repos opens each one once.
    def worktree(repo)
      (@worktrees ||= {})[repo.name] ||= Git.open(repo.worktree_host.to_s)
    end

    # Check out the WP's fix branch in `repo`, creating it from origin/<base> on
    # first use. `checkout -b` from a remote start point makes the new branch
    # track origin/<base>, which is dangerous: a bare `git pull` merges the base
    # into the fix branch, and with push.default=upstream a bare `git push`
    # targets the base itself. Re-point tracking at the branch's own name — the
    # PR branch it is pushed to — on every checkout, which also repairs branches
    # created before this fix.
    def checkout_branch(st, repo)
      wt = worktree(repo)
      if local_branch_exists?(wt, st.branch)
        wt.checkout(st.branch)
      else
        wt.checkout(st.branch, new_branch: true, start_point: "origin/#{repo.base}")
      end
      wt.config("branch.#{st.branch}.remote", "origin")
      wt.config("branch.#{st.branch}.merge", "refs/heads/#{st.branch}")
    end

    # Check out an existing PR's branch in `repo` and sync it to the PR's current
    # head. Unlike #checkout_branch (which starts new work from origin/<base>),
    # gh-agent acts on a branch that already lives on the remote. The caller must
    # first fetch that head into FETCH_HEAD over HTTPS (Clients::GitHub#fetch_branch)
    # — we then hard-reset onto FETCH_HEAD, building on the latest PR head and
    # never diverging. We reset to FETCH_HEAD rather than a remote-tracking ref so
    # this works without relying on the worktree's `origin` (which may be SSH and
    # unreachable in the container).
    def checkout_pr_branch(repo, branch)
      wt = worktree(repo)
      if local_branch_exists?(wt, branch)
        wt.checkout(branch)
        wt.reset_hard("FETCH_HEAD")
      else
        wt.checkout(branch, new_branch: true, start_point: "FETCH_HEAD")
      end
    end

    # Append a pipe-delimited line to the session progress log.
    def record_progress(id, branch, note)
      @ctx.progress_file.open("a") do |f|
        f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{id}|#{branch}|#{note}"
      end
    end

    # Build the ItemState for a WP, creating its items/<id>/ directory. The
    # target repos are loaded from target_repos.json (set once Claude picks them
    # in the plan); until then the state defaults to the registry's default repo.
    def state_for(item_id, subject, type = nil)
      dir = Helpers.item_dir(@ctx, item_id)
      dir.mkpath
      ItemState.new(
        item_id:           item_id.to_s,
        subject:           subject.to_s,
        branch:            branch_slug(item_id, type.to_s, subject.to_s),
        repos:             target_repos_for(item_id),
        item_dir:          dir,
        plan_file:         dir / "plan.md",
        item_file:         dir / "item.json",
        related_file:      dir / "related.json",
        review_file:       dir / "review.txt",
        target_repos_file: dir / "target_repos.json",
        session_file:      dir / "session_id"
      )
    end

    # The Repo objects a WP targets, read from items/<id>/target_repos.json (an
    # array of registry names); unknown names are dropped and an empty/missing
    # file falls back to the registry default, so single-repo flows just work.
    def target_repos_for(item_id)
      file  = Helpers.item_dir(@ctx, item_id) / "target_repos.json"
      names = Helpers.safe_json_read(file) if file.exist?
      repos = Array(names).filter_map { |n| @ctx.repos[n] }
      repos.empty? ? [@ctx.default_repo] : repos
    end

    # Persist the repos Claude chose for a WP (validated against the registry) and
    # update the live state. Names not in the registry are ignored; if none
    # survive, the default repo is used so a fix still ships somewhere.
    def set_target_repos(st, names)
      repos = Array(names).filter_map { |n| @ctx.repos[n.to_s.strip] }.uniq(&:name)
      repos = [@ctx.default_repo] if repos.empty?
      st.target_repos_file.write(JSON.generate(repos.map(&:name)))
      st.repos = repos
    end

    # Rewrite a host path under .chomper/ to its path inside the Claude container.
    def container_path(host_path)
      host_path.to_s.sub(@ctx.state_dir.to_s, @ctx.state_container)
    end

    # Rewrite a host path inside a repo's worktree to its /repos/<name> path
    # inside the Claude container.
    def container_path_for(repo, host_path)
      host_path.to_s.sub(repo.worktree_host.to_s, repo.worktree_container)
    end

    # Fetch a WP's related work packages (relations + parent/children) via the
    # injected @pull, write the index to related.json, and return its container
    # path — or nil when there are none, so the prompt omits the RELATED section.
    # Each related WP is also cached to its own item.json (by @pull) so Claude can
    # read the full detail on demand via the item_path in the index. Shared by the
    # op-agent (Agent) and the terminal backlog/fix flow (BacklogRunner).
    def related_ref(st)
      related = @pull.related_work_packages(st.item_id)
      return nil if related.empty?
      indexed = related.map do |r|
        r.merge("item_path" => container_path(Helpers.item_dir(@ctx, r["id"]) / "item.json"))
      end
      st.related_file.write(JSON.generate(indexed))
      container_path(st.related_file)
    end

    # Shape Repo objects for a prompt's repo listing — name, container path (where
    # Claude reads/edits the files), and the one-line description.
    def repos_for_prompt(repos)
      repos.map { |r| { name: r.name, path: r.worktree_container, description: r.description } }
    end

    # Read the `REPOS:` line Claude put at the top of a fresh plan, validate the
    # names against the registry, record the chosen repos, and strip the line from
    # the saved plan. Falls back to the default repo when the line is absent or
    # names nothing valid (so single-repo plans need no REPOS line).
    def record_chosen_repos(st)
      text  = st.plan_file.read
      m     = text.match(/^[ \t]*REPOS:[ \t]*(.+?)[ \t]*$/i)
      names = m ? m[1].split(",").map(&:strip).reject(&:empty?) : []
      set_target_repos(st, names)
      st.plan_file.write(text.sub(/^[ \t]*REPOS:.*\R?/i, "")) if m
    end

    def branch_has_commits?(st, repo)
      worktree(repo).log.between("origin/#{repo.base}", st.branch).execute.any?
    end

    # True when a phase will resume an existing per-WP session (so the plan and
    # issue are already in context). False for a fresh session — e.g. the first
    # call, or after the session was cleared — where the prompt must tell Claude
    # to read the plan instead of assuming it.
    def session_resumable?(st)
      Helpers.file_has_content?(st.session_file)
    end

    # Commit the worktree changes for one repo. Returns true when a commit was
    # made, false when this repo had no changes (so the caller can skip its PR).
    def commit(st, repo)
      Helpers.adopt_github_author!(@ctx)
      wt = worktree(repo)
      wt.add(all: true)
      diff = wt.diff("HEAD")
      return false if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      wt.commit(pr_title(st.item_id, st.subject))
      c = wt.log(1).execute.first
      log_script "Committed to #{repo.name}: #{c.sha[0, 7]} #{c.message}"
      record_progress(st.item_id, st.branch, "committed:#{repo.name}")
      true
    end

    def generate_pr_description(st, repo, model: Claude::MODEL_WORK)
      pr_desc_file = st.pr_desc_file(repo)
      return if Helpers.file_has_content?(pr_desc_file)
      wt               = worktree(repo)
      template_file    = repo.worktree_host / ".github" / "pull_request_template.md"
      template_section = template_file.exist? ? "Fill in this PR template exactly: #{container_path_for(repo, template_file)}" : ""
      diff_stat = wt.diff("HEAD~1", "HEAD").stats[:files]
        .map { |f, s| "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        .join("\n")
      prompt = Prompts.pr_description(
        item: container_path(st.item_file), plan: container_path(st.plan_file),
        diff_stat: diff_stat, template_section: template_section
      )
      pr_text = @claude.run(prompt, tools: Claude::TOOLS_READ, model: model, session_file: st.session_file)
      pr_body = pr_text[/^#.*/m] || pr_text
      pr_desc_file.write(strip_ansi(pr_body))
    end
  end
end
