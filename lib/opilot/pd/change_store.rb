require "fileutils"
require "json"
require "pathname"
require "git"

module OPilot
  module PD
    # The canonical spec store: one plain git repo per product repo, under
    # .opilot/openspec/<repo>/, holding that repo's openspec/ tree.
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

      # .opilot/openspec/<repo>/ — the root the openspec CLI resolves against, so
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
          raise OPilot::FatalError, "openspec init failed: #{result.message}" unless result.ok?
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
      # Re-asserts the exclude on EVERY call, not just at setup!: this is what puts
      # an untracked tree inside a live product clone, so it is what must guarantee
      # the tree can't be swept into an unrelated commit — a re-clone or a store
      # seeded on another machine would otherwise leave the window open.
      #
      # `preserve:` is false when the caller just wrote the store itself (`pd
      # intake` writes canonical, then materialises), so the older working copy is
      # not unsaved work; otherwise the safety net copies it aside every re-intake.
      def materialise!(preserve: true)
        exclude_from_clone!
        dest = working_tree
        dest.parent.mkpath
        preserve_unpersisted! if preserve
        FileUtils.rm_rf(dest.to_s)
        FileUtils.cp_r(tree.to_s, dest.to_s) if tree.exist?
        dest
      end

      # Where a working copy goes when materialise! is about to overwrite work that
      # was never persisted. Deliberately OUTSIDE the store root: commit! does
      # `add(all: true)` there, so a backup kept inside would be committed into the
      # store's history on the next persist! and never removed — the safety net
      # permanently inflating the durable copy it exists to protect.
      def superseded_dir
        @ctx.state_dir / "superseded" / @repo.name
      end

      # The working copy is disposable by design — but only once its contents are
      # in the store. A command that dies between materialise! and persist! (a
      # failed validation, a crash, a bug in the caller) leaves real work here that
      # the NEXT materialise! would delete without trace. Set it aside instead.
      #
      # Only the most recent is kept: this is a recovery hatch for "the last run
      # produced something and didn't save it", not an archive.
      def preserve_unpersisted!
        # Nothing to lose before the first materialise, and "canonical has files
        # the clone doesn't" is the normal state then — not unsaved work.
        return unless working_tree.directory?
        return if unpersisted_paths.empty?
        backup = superseded_dir
        FileUtils.rm_rf(backup.to_s)
        backup.parent.mkpath
        FileUtils.cp_r(working_tree.to_s, backup.to_s)
        warn "  ⚠ The working spec tree had unsaved changes; a copy is at #{backup}"
      rescue StandardError => e
        # Never let the safety net stop the command it is protecting.
        warn "  ⚠ Could not preserve the unsaved working spec tree: #{e.message}"
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
      # `outside:` narrows to paths NOT under that prefix, and narrows BEFORE the
      # contents are compared — the caller asking "did anything escape this change
      # directory?" would otherwise read every converted attachment in the store
      # only to discard it by prefix afterwards.
      def working_changes(outside: nil)
        candidates = paths_under(working_tree) | paths_under(tree)
        candidates = candidates.reject { |rel| rel.start_with?(outside) } if outside
        candidates.reject { |rel| same_content?(rel) }.sort
      end

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

      def head_sha
        git.log(1).execute.first&.sha
      rescue StandardError
        nil
      end

      private

      # Files that exist in the WORKING copy and are new or edited relative to the
      # store. Deliberately one-directional, unlike #working_changes: a file the
      # store has and the clone doesn't is something materialise! is about to
      # restore, not work about to be lost.
      def unpersisted_paths
        paths_under(working_tree).reject { |rel| same_content?(rel) }
      end

      # The one "are these the same file?" rule, shared by both directional
      # comparisons above so they can't drift apart.
      def same_content?(rel)
        a = working_tree / rel
        b = tree / rel
        a.file? && b.file? && a.read == b.read
      end

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
      STORE_AUTHOR_NAME  = "opilot".freeze
      STORE_AUTHOR_EMAIL = "opilot@localhost".freeze

      def git_init!
        fresh = !(root / ".git").exist?
        if fresh
          Git.init(root.to_s)
          @git = nil
        end
        return unless fresh || configured_email.empty?
        git.config_set("user.name", STORE_AUTHOR_NAME)
        git.config_set("user.email", STORE_AUTHOR_EMAIL)
      end

      # `config_get` answers with a Git::ConfigEntryInfo (scope, origin, key,
      # value), not the bare string the removed `config` reader returned — hence
      # `.value`. It is nil when the key is unset, which `&.` turns back into the
      # empty string #git_init! tests for.
      def configured_email
        git.config_get("user.email")&.value.to_s
      rescue StandardError
        ""
      end

      # Commit everything in the store. Returns true when a commit was made.
      # Authored by whatever identity ./opilot exported — the store is local and
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
        status = git_repo.status_info
        !(status.changed.empty? && status.added.empty? && status.deleted.empty?)
      end
    end
  end
end
