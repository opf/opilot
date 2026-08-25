require_relative "clients"

module OPilot
  class Publish
    include Helpers

    # opilot has one publishing identity: the CONTRIBUTOR bot. It forks the
    # upstream, pushes the branch to its own fork, and opens a cross-repo draft
    # PR — nothing opilot produces is ever pushed to a canonical repo, so a
    # maintainer's review and merge is always the gate.
    def initialize(ctx)
      @ctx    = ctx
      @github = Clients::GitHub.new(author_token)
    end

    # The bot's token — also the author identity adopted for commits, so a PR's
    # commits match its opener.
    def author_token
      @ctx.contributor_token
    end

    # The env var that supplies it, so a caller that has to tell the operator
    # what to set names it in one place.
    def token_env_var
      "GITHUB_CONTRIBUTOR_TOKEN"
    end

    # Push the WP's fix branch in `repo` and open a draft PR there, returning the
    # PR URL (or nil on failure). Idempotent: an already-open PR is recorded and
    # returned. Upstream, base branch, and worktree all come from `repo`, so a WP
    # that spans several repos opens an independent PR in each.
    def open_pr(item_id, subject, branch, repo)
      unless author_token
        puts "  Error: #{token_env_var} is not set — cannot open PRs."
        return nil
      end

      st           = state_for(item_id, subject)
      pr_desc_file = st.pr_desc_file(repo)
      pr_url_file  = st.pr_url_file(repo)
      upstream     = repo.upstream
      base         = st.base_for(repo)

      unless local_branch_exists?(worktree(repo), branch)
        puts "  Error: branch #{branch} not found in #{repo.name} — has this item been committed?"
        return nil
      end
      unless Helpers.file_has_content?(pr_desc_file)
        puts "  Error: no PR description at #{pr_desc_file} (missing or empty)"
        return nil
      end

      # The branch goes to the bot's fork and the PR is opened against upstream
      # with a cross-repo head ("fork_owner:branch"), keeping the token off the
      # canonical repo.
      target_repo = @github.ensure_fork(upstream)
      head        = "#{target_repo.split('/').first}:#{branch}"

      existing = @github.find_open_pr(upstream, head: head)
      if existing
        pr_url_file.write(existing)
        return existing
      end

      log_script "Publishing #{wp_label(item_id)} → #{repo.name} (base #{base}, via #{target_repo}) — #{subject}"

      # Keep the PR body compact; the full plan is attached as a secret gist and
      # linked below the banner. The bot-specific preamble (disclaimer + adopt
      # note) is fenced in HTML comments so `opilot-adopt` can lift exactly that block
      # out — a maintainer's own PR is not AI-generated and cannot be adopted
      # twice. The markers are a contract; matching on the prose would break the
      # moment its wording changed. The plan link sits OUTSIDE the fence, so it
      # survives adoption. The adopt note lands as a second bullet
      # (#add_adopt_note, post-create, once the PR number exists).
      banner    = "🤖 This is an AI-generated prototype.\n\n" \
                  "* To ask for a change, write a comment to @#{@github.login} on this PR."
      gist_url  = plan_gist_url(st)
      plan_line = gist_url ? "📋 **Implementation plan:** #{gist_url}\n\n" : ""
      pr_body   = "#{BANNER_OPEN}\n#{banner}\n#{BANNER_CLOSE}\n\n#{plan_line}#{pr_desc_file.read}"

      # The PR lives on upstream but isn't a maintainer's PR yet — defang its WP
      # link (http→hxxp) so the OpenProject GitHub integration doesn't
      # auto-reference the WP and clutter its activity tab (`opilot-adopt` re-fangs
      # it when a maintainer promotes it).
      pr_body = neutralize_wp_links(pr_body)

      # Backstop: the target is the bot's fork, so this never fires — unless
      # ensure_fork resolved to the upstream itself, which must not be pushed to.
      if refuse_canonical_push?(target_repo, branch)
        puts "  #{branch} was not pushed and no PR was opened."
        return nil
      end
      @github.push_branch(target_repo, branch: branch, worktree_path: repo.worktree_host)

      title = pr_title(item_id, subject)
      url = @github.create_draft_pr(upstream, base: base, head: head, title: title, body: pr_body,
                                    maintainer_can_modify: true)
      add_adopt_note(upstream, url, pr_body, banner)
      pr_url_file.write(url)
      record_progress(item_id, branch, "published:#{repo.name}")
      url
    end

    # The login of the identity publishing, for PR bodies that invite a reply.
    def login
      @github.login
    end

    # The token's classic-PAT scopes, for `pd init`'s preflight. Empty means
    # "unknown" (fine-grained token, or the call failed), not "none".
    def token_scopes
      @github.token_scopes
    end

    # Push a `pd` change's spec branch and open its proposal PR **inside the bot's
    # own fork** — head and base both `<bot>/<repo>`.
    #
    # Deliberately not against upstream: the diff is planning artifacts, so it
    # would be noise on a public repo, and the bot owning both sides can merge or
    # close freely. Nothing downstream needs the merge — `generate-wp` reads the
    # local store. Idempotent: an already-open PR for this head is returned.
    def open_spec_pr(state, repo, body:)
      unless author_token
        puts "  Error: GITHUB_CONTRIBUTOR_TOKEN is not set — cannot open the proposal PR."
        return nil
      end

      fork   = @github.ensure_fork(repo.upstream)
      branch = state.branch
      head   = "#{fork.split("/").first}:#{branch}"

      existing = @github.find_open_pr(fork, head: head)
      if existing
        state.pr_url_file.write(existing)
        return existing
      end

      base = state.base_for(repo)
      log_script "Publishing proposal #{state.change_id} → #{fork} (base #{base})"

      # Level the fork's base with upstream FIRST. The spec branch is cut from
      # the clone, which tracks upstream; the PR's base is the fork's copy of the
      # same branch. Left stale, the diff shows every upstream commit since the
      # fork was created alongside the spec files, and the PR is unreviewable.
      @github.sync_fork_branch(fork, branch: base)

      if refuse_canonical_push?(fork, branch)
        # Say why: without this the caller reports "couldn't open the PR — is
        # GITHUB_CONTRIBUTOR_TOKEN set?", naming the wrong cause entirely.
        puts "  #{branch} was not pushed and no PR was opened."
        return nil
      end
      @github.push_branch(fork, branch: branch, worktree_path: repo.worktree_host)

      url = @github.create_draft_pr(
        fork, base: base, head: branch,
        title: "[#{state.change_id}] Change proposal",
        # A same-repo PR 422s unless maintainer edits are off.
        body: body, maintainer_can_modify: false
      )
      state.pr_url_file.write(url)
      record_progress(state.change_id, branch, "proposal-pr")
      url
    end

    private

    # Where `opilot-adopt` (how to get it, how to run it) is documented. The
    # anchor must match the README heading's slug, or the link lands at the top
    # of the page.
    ADOPT_DOC_URL = "https://github.com/opf/opilot#adopting-an-opilot-pr"

    # Fence around the bot-only preamble of a PR body. `opilot-adopt` deletes
    # this range verbatim, so these two lines are a published interface: changing
    # either string orphans every PR opened before the change (an old PR's fence
    # no longer matches the new script, and vice versa), and adoption then
    # silently keeps the AI disclaimer on a maintainer's PR.
    BANNER_OPEN  = "<!-- opilot:banner -->"
    BANNER_CLOSE = "<!-- /opilot:banner -->"

    # Every opilot PR is opened cross-repo against upstream from the bot's fork,
    # which can't run secret-gated CI, so tell maintainers up front how to
    # re-publish it under their own account. The PR lives in the upstream repo, so
    # a bare number resolves against the maintainer's canonical checkout. The
    # number only exists after creation — hence the follow-up body edit.
    # Appended as the banner's second bullet, so it stays inside the fence
    # `opilot-adopt` deletes (an adopted PR must not tell its owner to adopt it).
    # Best-effort: a failed update just leaves the note off.
    def add_adopt_note(upstream, url, pr_body, banner)
      number = Clients::GitHub.pr_number_from_url(url)
      return unless number
      note = "* To ship the PR, first make it yours: run `opilot-adopt #{number}` " \
             "([setup guide](#{ADOPT_DOC_URL}))."
      @github.update_pr_body(upstream, number, pr_body.sub(banner, "#{banner}\n#{note}"))
    rescue => e
      log_script "Could not add the adopt note to #{url}: #{e.message}"
    end

    # The secret gist URL for this WP's plan, created once and cached in
    # gist_url.txt so every repo's PR links the same gist. nil when there is no
    # plan to upload or the gist call fails (the PR then opens with no plan link).
    def plan_gist_url(st)
      cache = st.gist_url_file
      return cache.read.strip if Helpers.file_has_content?(cache)
      return nil unless Helpers.file_has_content?(st.plan_file)

      url = @github.create_gist(
        description: "opilot plan: #{wp_label(st.item_id)} — #{st.subject}",
        filename:    "wp-#{st.item_id}-plan.md",
        content:     st.plan_file.read
      )
      cache.write(url) if url
      url
    end
  end
end
