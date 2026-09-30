module OPilot
  module Helpers
    # Git work in the clones: the push-safety rule, branches, syncing a clone
    # to upstream, staging and committing.

    # Set the process git identity (author + committer) to the GitHub account
    # the given token belongs to, so a PR's commits are attributed to the
    # identity that publishes it and the operator's private email never lands
    # on a public PR. Runs once per process; a no-op when no token is given
    # (planning-only). Falls back silently to the host identity ./opilot
    # exported if the lookup fails.
    def self.adopt_github_author!(token)
      return if @github_author_adopted
      return unless token
      name, email = Clients::GitHub.new(token).author_identity
      ENV["GIT_AUTHOR_NAME"]  = ENV["GIT_COMMITTER_NAME"]  = name
      ENV["GIT_AUTHOR_EMAIL"] = ENV["GIT_COMMITTER_EMAIL"] = email
      @github_author_adopted = true
    rescue StandardError => e
      warn "  Warning: couldn't resolve the publishing git identity (#{e.message}); using host git identity"
    end

    # The one push-safety rule: no push ever lands on a canonical repo (a
    # registry upstream). opilot publishes only from the contributor bot's own
    # fork, so a canonical target is always a mistake — the head of a PR a
    # maintainer adopted, or a fork lookup that resolved to the upstream itself
    # — and is refused outright rather than prompted for. Pushes anywhere else
    # (the bot's fork) pass straight through. Returns true when the push must
    # NOT happen, so callers read `return if refuse_canonical_push?(…)`.
    def refuse_canonical_push?(target_repo, branch)
      return false unless canonical_repo?(target_repo)
      log_script "Refusing to push #{branch} to #{target_repo} — opilot only pushes to the " \
                 "contributor bot's fork; a canonical repo is a maintainer's to write to."
      true
    end

    # Is this "owner/repo" one of the registry upstreams, i.e. a canonical repo?
    # (Registry#by_upstream can't answer this — it falls back to the default repo.)
    def canonical_repo?(owner_repo)
      @ctx.repos.all.any? { |r| r.upstream.casecmp?(owner_repo.to_s) }
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
    #
    # The clone check lives here rather than in each command because this is the
    # funnel every git operation goes through — a check any caller could forget
    # is a check that will be forgotten.
    def worktree(repo)
      (@worktrees ||= {})[repo.name] ||= begin
        require_clone!(repo)
        Git.open(repo.worktree_host.to_s)
      end
    end

    # `./opilot` provisions the clones, but a clone whose `git clone` failed (a
    # wrong `base` in repos.json, a network blip) only WARNS and is skipped — so
    # this state is reachable, and every later stage needs the clone: it is where
    # the LLM writes, and its `.git/info/exclude` is what keeps a `pd` spec tree
    # out of unrelated commits (installed silently, so its absence says nothing).
    # Raised instead of letting Git.open surface `path does not exist`, which
    # names neither the repo nor the fix.
    def require_clone!(repo)
      return if (repo.worktree_host / ".git").exist?
      raise OPilot::FatalError, <<~MSG.strip
        No git clone for #{repo.name} at #{repo.worktree_host}.
        Run `./opilot` once to provision the clones (it warns and skips a repo whose
        clone failed — check that repo's "base" branch in repos.json), then re-run.
      MSG
    end

    # Check out the WP's fix branch in `repo`, creating it from origin/<base> on
    # first use. `checkout -b` from a remote start point makes the new branch
    # track origin/<base>, which is dangerous: a bare `git pull` merges the base
    # into the fix branch, and with push.default=upstream a bare `git push`
    # targets the base itself. Re-point tracking at the branch's own name — the
    # PR branch it is pushed to — on every checkout.
    def checkout_branch(st, repo)
      wt   = worktree(repo)
      base = st.base_for(repo)
      # Always fetch, including the default base. `./opilot` fetches it once at
      # launch, which an agent loop then outruns: a week-old process would cut
      # every new fix branch from week-old upstream. A non-default base may not be
      # in the clone at all (clones aren't --single-branch, so default-base
      # siblings exist, but a newer/less-common base needs fetching).
      fetch_base(wt, repo, base)
      if local_branch_exists?(wt, st.branch)
        wt.checkout(st.branch)
      else
        clear_leftovers!(wt, repo)
        wt.checkout(st.branch, new_branch: true, start_point: "origin/#{base}")
      end
      wt.config_set("branch.#{st.branch}.remote", "origin")
      wt.config_set("branch.#{st.branch}.merge", "refs/heads/#{st.branch}")
    end

    # Clear the clone before a NEW work branch is cut from it. Nothing else
    # removes an untracked file — not a checkout, not #sync_base! — so one an
    # earlier run left behind sits there until the next WP's `git add --all`
    # sweeps it into ITS commit (opf/openproject#24916).
    #
    # New-branch path only: an existing branch may be a run resuming after it
    # died between the LLM writing files and the commit, and that work is its own.
    #
    # Reset to HEAD, not origin/<base>: HEAD may still be a previous WP's branch,
    # and resetting to the base would rewind it. HEAD moves no ref, only the tree.
    # No `x:` — the pd spec tree is git-excluded by design, and pd cuts branches
    # through here too. Never fatal, and every discarded path is logged: a file
    # appearing from nowhere is the bug, so removing one silently repeats it.
    def clear_leftovers!(wt, repo)
      leftovers = wt.clean(force: true, d: true, dry_run: true).to_s.lines.map(&:strip).reject(&:empty?)
      leftovers.each { |line| log_script "#{repo.name}: discarding leftover — #{line}" }
      wt.reset("HEAD", hard: true)
      wt.clean(force: true, d: true)
    rescue StandardError => e
      log_script "#{repo.name}: could not clear the clone before branching (#{e.message}) — " \
                 "anything left in it may end up in this commit."
    end

    # Fetch a base branch into its remote-tracking ref (origin/<base>) so the fix
    # branch can be created from it. Read-only over the clone's public https
    # origin, so no auth — mirrors how ./opilot provisions the default base. A
    # missing branch surfaces as a clear error the runner reports on the WP.
    def fetch_base(wt, repo, base)
      wt.fetch("origin", ref: base)
    rescue StandardError => e
      raise "base branch #{base.inspect} not found on #{repo.upstream} (#{e.message})"
    end

    # Refspecs the READ phases answer questions from. #fetch_base pulls exactly
    # ONE ref — the base — so every tag and every release/* branch in a clone
    # stays as-of-clone-time, and nothing else ever updates them. That is worse
    # than it sounds: the clone still HAS a release/17.6 and a tag list to
    # compare against, so "is this commit in 17.6?" gets a confident answer off
    # a months-old snapshot, with nothing in the tree saying so.
    #
    # Narrow on purpose. Fetching every head would put the openproject
    # monorepo's full branch list on every plan and chat; release/* plus tags is
    # what a "has this shipped yet?" question actually reads.
    RELEASE_REFSPEC = "+refs/heads/release/*:refs/remotes/origin/release/*".freeze

    # Best-effort, unlike #fetch_base: a repo with no release/* namespace is
    # normal (a glob refspec matching nothing is not an error to git), and a
    # stale tag beats a failed chat. Only the READ path calls this —
    # #checkout_branch needs the base and nothing else, and would pay the cost
    # on every implement run for nothing.
    def fetch_read_refs(wt, repo)
      wt.fetch("origin", ref: RELEASE_REFSPEC, tags: true)
    rescue StandardError => e
      log_script "#{repo.name}: could not refresh tags and release branches (#{e.message}) — " \
                 "answers about tags and releases may be stale."
    end

    # Point `repo`'s clone at current upstream before a READ-ONLY phase (plan,
    # chat). Nothing else does: `./opilot` fetches each base once at launch
    # without moving the tree, and no run checks the tree back off its fix branch
    # — so a plan would otherwise be written against the original clone commit,
    # or against another WP's leftover branch, with nothing in the tree saying so.
    # Tags and release/* come along too (#fetch_read_refs) — the read phases are
    # asked about them, and no other code path fetches them at all.
    #
    # Detached at origin/<base>, since a local base branch would be a second thing
    # to keep in sync; #checkout_branch cuts fix branches from origin/<base>
    # regardless of HEAD. Never fatal — a stale answer beats no answer. A DIRTY
    # tree is left strictly alone: it means an implement run died after the LLM
    # wrote files but before #commit, and a checkout would discard that work.
    def sync_base!(repo)
      wt = worktree(repo)
      if dirty_worktree?(wt)
        log_script "#{repo.name}: uncommitted changes in the clone — reading it as-is, not syncing."
        return false
      end
      fetch_base(wt, repo, repo.base)
      fetch_read_refs(wt, repo)
      wt.checkout("origin/#{repo.base}")
      true
    rescue StandardError => e
      log_script "#{repo.name}: could not sync to origin/#{repo.base} (#{e.message}) — reading the clone as-is."
      false
    end

    # Untracked files are deliberately not counted: a `pd` spec tree lives in the
    # clone untracked-and-git-excluded by design, and the LLM's own scratch output
    # would otherwise pin the tree to a stale commit forever.
    def dirty_worktree?(wt)
      st = wt.status_info
      st.changed.any? || st.added.any? || st.deleted.any?
    end

    # Sync every clone the LLM is about to read. One log line for the set, since
    # #sync_base! already reports the cases worth seeing (dirty tree, fetch
    # failure) and a per-repo "ok" on a whole-registry plan is just noise.
    def sync_bases_for_reading(repos)
      list = Array(repos)
      return if list.empty?
      log_script "Syncing #{list.length} clone#{list.length == 1 ? "" : "s"} to current upstream"
      list.each { |repo| sync_base!(repo) }
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
        wt.reset("FETCH_HEAD", hard: true)
      else
        wt.checkout(branch, new_branch: true, start_point: "FETCH_HEAD")
      end
    end

    def branch_has_commits?(st, repo)
      worktree(repo).log.between("origin/#{st.base_for(repo)}", st.branch).execute.any?
    end

    # Stage everything in `wt` and return the diff, or nil when there is nothing
    # to commit. Prints the per-file stat lines, which a caller always wants
    # immediately before committing. This is the one definition of "did the LLM
    # change anything?", and it hands the diff back rather than making a caller
    # that needs to describe it take a second one.
    def stage_all(wt)
      wt.add(all: true)
      diff = wt.diff("HEAD")
      return nil if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      diff
    end

    # Commit the staged tree and report the commit in one format everywhere.
    # `where` names the repo when a run spans several of them; a single-repo
    # context leaves it off.
    def commit_and_log(wt, message, where = nil)
      wt.commit(message)
      c = wt.log(1).execute.first
      log_script "Committed#{where ? " to #{where}" : ""}: #{c.sha[0, 7]} #{c.message}"
      c
    end
  end
end
