require "fileutils"
require "json"
require "pathname"

module Chomper
  # Per-change working state for the `pd` (product development) pipeline.
  #
  # chomper's bug-fix flow keys everything on a work-package id
  # (Helpers::ItemState); this pipeline keys on a CHANGE id, with a tree of work
  # packages hanging off it. The two live side by side and never share state.
  #
  # The spec tree exists in three copies, and every `pd` command moves between
  # them (see ChangeStore below):
  #
  #   canonical  .chomper/openspec/<repo>/       runner-owned git repo, the truth
  #   working    <clone>/openspec/               where guard-writes.js lets Claude write
  #   review     branch spec/<change-id> on the bot's fork   the PR diff surface
  ChangeState = Struct.new(:change_id, :store, :state_dir, keyword_init: true) do
    # The repo is the store's — carrying it as a second member only created a
    # way for the two to disagree.
    def repo
      store.repo
    end

    # Per-change local cache files. Derived rather than stored: they are all
    # `state_dir / <name>`, and gh-agent will need to build the same paths from
    # a directory at M1, so the names have to live in one place.
    def session_file    = state_dir / "session_id"
    def pr_url_file     = state_dir / "pr_url.txt"
    def gh_pr_file      = state_dir / "gh_pr.json"
    def gh_session_file = state_dir / "gh_session_id"

    # --- canonical (the store) ------------------------------------------

    def store_change_dir
      store.change_dir(change_id)
    end

    # tracker.json lives in the store, committed with the change (§4) — it is
    # the mapping the filesystem can't express: parent WP, intake identity, the
    # originating commit. Deliberately NOT under .chomper/, which is a cache.
    def tracker_file
      store_change_dir / "tracker.json"
    end

    def intake_dir
      store_change_dir / "intake"
    end

    # --- working (inside the product clone) ------------------------------

    def working_change_dir
      store.working_change_dir(change_id)
    end

    # The path Claude is given, inside the claude container.
    def working_change_container
      "#{repo.worktree_container}/openspec/changes/#{change_id}"
    end

    # --- review ----------------------------------------------------------

    def branch
      "spec/#{change_id}"
    end

    # The branch the spec branch is cut from, and the base a fork-internal PR
    # targets. Named to match Helpers::ItemState#base_for so the shared
    # checkout_branch helper works on a ChangeState unchanged; a change has no
    # per-repo base override, so it is always the registry default.
    def base_for(_repo = nil)
      repo.base
    end

    def archive_branch
      "archive/#{change_id}"
    end

    # --- tracker.json -----------------------------------------------------

    def tracker
      Helpers.safe_json_read(tracker_file) || {}
    end

    def write_tracker(data)
      store_change_dir.mkpath
      # Atomic like every other cache chomper writes, and pretty because this one
      # is committed into the store and read in PR diffs.
      Helpers.write_json_atomic(tracker_file, data, "tracker", pretty: true)
    end

    def merge_tracker(fields)
      write_tracker(tracker.merge(fields))
    end

    def parent_wp
      tracker["parent_wp"]
    end
  end

  # The canonical spec store: one plain git repo per product repo, under
  # .chomper/openspec/<repo>/, holding that repo's openspec/ tree.
  #
  # Why a store at all, rather than just leaving the tree in the clone: the
  # working copy lives inside a product clone whose branch is switched
  # constantly (fix branches, PR heads), and `openspec/` is deliberately
  # git-excluded there so it can never be swept into an unrelated commit. That
  # makes the clone copy disposable, so the durable copy has to live elsewhere.
  # It is versioned rather than a bare directory so a bad propose or archive run
  # is recoverable.
  class ChangeStore
    include Helpers

    EXCLUDE_ENTRY = "openspec/".freeze

    def initialize(ctx, repo)
      @ctx  = ctx
      @repo = repo
    end

    attr_reader :repo

    # .chomper/openspec/<repo>/ — the root the openspec CLI resolves against, so
    # the tree itself sits at <root>/openspec/, mirroring the product clone.
    def root
      @ctx.state_dir / "openspec" / @repo.name
    end

    def tree
      root / "openspec"
    end

    def changes_dir
      tree / "changes"
    end

    def change_dir(change_id)
      changes_dir / change_id
    end

    def initialized?
      (tree / "config.yaml").exist?
    end

    def working_tree
      @repo.worktree_host / "openspec"
    end

    def working_change_dir(change_id)
      working_tree / "changes" / change_id
    end

    # Create the store, seed it via `openspec init --tools none` (which writes
    # only openspec/ — never the AGENTS.md the product clone really has), and
    # make the first commit. Idempotent.
    def setup!
      root.mkpath
      git_init!
      unless initialized?
        result = OpenSpec.new(root).init!
        raise Chomper::FatalError, "openspec init failed: #{result.message}" unless result.ok?
      end
      commit!("Initialise the OpenSpec store for #{@repo.name}")
      exclude_from_clone!
      root
    end

    # Append `openspec/` to the CLONE's .git/info/exclude, so the working copy
    # can never be picked up by Helpers#commit's `add(all: true)` and swept into
    # an unrelated bug-fix commit. Local to the clone: it never touches the
    # product repo's own .gitignore and is invisible upstream. The propose flow
    # commits the tree deliberately with `git add -f`, which overrides this.
    def exclude_from_clone!
      info = @repo.worktree_host / ".git" / "info"
      return unless info.dirname.directory?
      info.mkpath
      file = info / "exclude"
      current = file.exist? ? file.read : ""
      return if current.lines.map(&:strip).include?(EXCLUDE_ENTRY)
      file.write("#{current}#{current.end_with?("\n") || current.empty? ? "" : "\n"}#{EXCLUDE_ENTRY}\n")
    end

    # Canonical → working. Mirrors rather than merges: an archive run MOVES a
    # change directory, so a merge would resurrect what it moved away.
    #
    # Re-asserts the exclude on every call, not just at setup!: this is the
    # operation that puts an untracked tree inside a live product clone, so it
    # is the one that has to guarantee the tree can't be swept into an unrelated
    # commit. A re-clone, a manual .git/info/exclude edit, or a store seeded on
    # another machine would otherwise leave the window open.
    def materialise!
      exclude_from_clone!
      dest = working_tree
      dest.parent.mkpath
      FileUtils.rm_rf(dest.to_s)
      FileUtils.cp_r(tree.to_s, dest.to_s) if tree.exist?
      dest
    end

    # Working → canonical, then commit. Same mirror semantics, opposite
    # direction. A no-op commit is fine; #commit! swallows an empty index.
    def persist!(message)
      src = working_tree
      return unless src.exist?
      FileUtils.rm_rf(tree.to_s)
      FileUtils.cp_r(src.to_s, tree.to_s)
      commit!(message)
    end

    # Paths under the WORKING openspec/ tree that differ from the canonical
    # store, relative to the tree root (e.g. "changes/add-x/proposal.md").
    #
    # This is how the path allowlist sees inside openspec/: the tree is in
    # .git/info/exclude, so `git status` in the clone reports nothing about it
    # and cannot answer "did this run only touch its own change directory?".
    def working_changes
      (paths_under(working_tree) | paths_under(tree)).reject do |rel|
        a = working_tree / rel
        b = tree / rel
        a.file? && b.file? && a.read == b.read
      end.sort
    end

    # Every change id present in the store.
    def change_ids
      return [] unless changes_dir.directory?
      changes_dir.children
                 .select(&:directory?)
                 .map { |d| d.basename.to_s }
                 .reject { |n| n == "archive" }
                 .sort
    end

    # Reverse index: work-package id => { change_id:, section: }.
    #
    # Rebuilt from tasks.md on every call and never cached — the repo is the
    # source of truth for what a work package belongs to (§3), so a stale index
    # would be worse than none. `pd implement <wp-id>` resolves its change here.
    def reverse_index
      change_ids.each_with_object({}) do |cid, index|
        tasks = change_dir(cid) / "tasks.md"
        next unless tasks.exist?
        TasksFile.parse(tasks.read).each do |section|
          next unless section.wp_id
          index[section.wp_id.to_s] = { change_id: cid, section: section.title }
        end
      end
    end

    def change_id_for_wp(wp_id)
      reverse_index.dig(wp_id.to_s, :change_id)
    end

    def head_sha
      git.log(1).execute.first&.sha
    rescue StandardError
      nil
    end

    private

    # Every file under `root`, as paths relative to it.
    def paths_under(root)
      return [] unless root.directory?
      Pathname.glob(root / "**" / "*").select(&:file?).map { |p| p.relative_path_from(root).to_s }
    end

    def git
      @git ||= Git.open(root.to_s)
    end

    # Identity for store commits. The store is local bookkeeping that is never
    # pushed, so it carries its own rather than depending on the host git config
    # or a GitHub token being present — persisting the only durable copy of the
    # spec tree must not fail because GIT_AUTHOR_EMAIL happens to be unset.
    STORE_AUTHOR_NAME  = "chomper".freeze
    STORE_AUTHOR_EMAIL = "chomper@localhost".freeze

    def git_init!
      fresh = !(root / ".git").exist?
      if fresh
        Git.init(root.to_s)
        @git = nil
      end
      return unless fresh || configured_email.empty?
      git.config("user.name", STORE_AUTHOR_NAME)
      git.config("user.email", STORE_AUTHOR_EMAIL)
    end

    def configured_email
      git.config("user.email").to_s
    rescue StandardError
      ""
    end

    # Commit everything in the store. Returns true when a commit was made.
    # Authored by whatever identity ./chomper exported — the store is local and
    # never pushed, so it needs no GitHub identity.
    #
    # Initialises the repo if it is missing rather than assuming setup! ran: the
    # store is the only durable copy of the spec tree, so a persist must never
    # fail just because .git was lost.
    def commit!(message)
      git_init!
      g = git
      g.add(all: true)
      return false unless dirty?(g)
      g.commit(message)
      true
    rescue Git::FailedError => e
      # A commit with nothing staged raises rather than reporting a clean index.
      raise unless e.message.match?(/nothing to commit|no changes added/i)
      false
    end

    # Before the first commit there is no HEAD to diff against, so `git status`
    # reports nothing changed and a naive check would skip the initial commit
    # forever — leaving the store unversioned exactly when it matters most.
    # Anything staged in that state is the first commit.
    def dirty?(git_repo)
      return true unless head_sha
      status = git_repo.status
      !(status.changed.empty? && status.added.empty? && status.deleted.empty?)
    end
  end
end
