require "fileutils"
require "json"
require "pathname"

module OPilot
  module PD
    # Per-change working state for the `pd` (product development) pipeline.
    #
    # opilot's bug-fix flow keys everything on a work-package id
    # (Helpers::ItemState); this pipeline keys on a CHANGE id, with a tree of work
    # packages hanging off it. The two live side by side and never share state.
    #
    # The spec tree exists in three copies, and every `pd` command moves between
    # them (see ChangeStore below):
    #
    #   canonical  .opilot/openspec/<repo>/       runner-owned git repo, the truth
    #   working    <clone>/openspec/               where pi-guards.ts lets the LLM write
    #   review     branch spec/<change-id> on the bot's fork   the PR diff surface
    ChangeState = Struct.new(:change_id, :store, :state_dir, keyword_init: true) do
      # The repo is the store's — carrying it as a second member only created a
      # way for the two to disagree.
      def repo
        store.repo
      end

      # Per-change local cache files. Derived rather than stored: they are all
      # `state_dir / <name>`. gh-agent's own per-PR state (gh_pr.json,
      # gh_session_id) is deliberately NOT here — it keys on a PR directory from
      # `GhPull#pr_dir(…, spec: true)` rather than on a change, so accessors for it
      # on this class went unused and were removed.
      def session_file = state_dir / "session_id"
      def pr_url_file  = state_dir / "pr_url.txt"

      # --- canonical (the store) ------------------------------------------

      def store_change_dir
        store.change_dir(change_id)
      end

      # tracker.json lives in the store, committed with the change (§4) — it is
      # the mapping the filesystem can't express: parent WP, intake identity, the
      # originating commit. Deliberately NOT under .opilot/, which is a cache.
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

      # The path the LLM is given, inside the harness container.
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

      # --- tracker.json -----------------------------------------------------

      def tracker
        Helpers.safe_json_read(tracker_file) || {}
      end

      def write_tracker(data)
        store_change_dir.mkpath
        # Atomic like every other cache opilot writes, and pretty because this one
        # is committed into the store and read in PR diffs.
        Helpers.write_json_atomic(tracker_file, data, "tracker", pretty: true)
        mirror_tracker_to_working(data)
      end

      # The tracker is runner-owned and lives in the canonical store, but it is also
      # part of the change directory the spec branch commits — so both copies have
      # to carry it. Writing only canonical made the write survive or vanish
      # depending on which way the NEXT mirror happened to run: `pd intake` writes
      # the tracker and then materialises (canonical → working), so it stuck, while
      # a stage that writes it and then persists (working → canonical) had the older
      # working copy mirrored straight back over it. `generate-wp` does exactly
      # that, and lost the parent work-package id every run — which is how you get a
      # duplicate FEATURE, since nothing can delete the first one.
      def mirror_tracker_to_working(data)
        dir = working_change_dir
        return unless dir.directory?
        Helpers.write_json_atomic(dir / "tracker.json", data, "tracker", pretty: true)
      rescue StandardError => e
        # Canonical is the durable copy and it is already written; a clone that has
        # gone missing must not fail the stage that wrote it.
        warn "  ⚠ Could not mirror tracker.json into the working copy: #{e.message}"
      end

      def merge_tracker(fields)
        write_tracker(tracker.merge(fields))
      end

      def parent_wp
        tracker["parent_wp"]
      end
    end
  end
end
