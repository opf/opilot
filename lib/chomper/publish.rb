require_relative "clients"

module Chomper
  class Publish
    include Helpers

    # chomper has one publishing identity: the CONTRIBUTOR bot. It forks the
    # upstream, pushes the branch to its own fork, and opens a cross-repo draft
    # PR — nothing chomper produces is ever pushed to a canonical repo, so a
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

      # Keep the PR body compact; attach the full plan as a (secret) gist and
      # link it under the banner for anyone who wants to read deeper.
      # The bot-specific preamble (disclaimer + adopt note) is fenced in HTML
      # comments so `gh adopt` can lift exactly that block out and say "Adapted
      # from #<n>" instead — a maintainer's own PR is not AI-generated and can't
      # be adopted twice. Matching on the banner's prose would break the moment
      # its wording changed; the markers are a contract. The plan link sits
      # OUTSIDE the fence: it documents the change, so it survives adoption.
      # A line of framing, then one bullet per thing a reader can do — the adopt
      # note lands as the second bullet (#add_adopt_note, post-create). Cramming
      # both into one sentence read as fine print on a wide GitHub body.
      banner    = "🤖 This is an AI-generated prototype.\n\n" \
                  "* Chat with @#{@github.login} for any further adjustments."
      gist_url  = plan_gist_url(st)
      plan_line = gist_url ? "📋 **Implementation plan:** #{gist_url}\n\n" : ""
      pr_body   = "#{BANNER_OPEN}\n#{banner}\n#{BANNER_CLOSE}\n\n#{plan_line}#{pr_desc_file.read}"

      # The PR lives on upstream but isn't a maintainer's PR yet — defang its WP
      # link (http→hxxp) so the OpenProject GitHub integration doesn't
      # auto-reference the WP and clutter its activity tab (`gh adopt` re-fangs
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

    # Push a `pd` change's spec branch and open its proposal PR **inside the
    # bot's own fork** — head and base both on `<bot>/<repo>`.
    #
    # Deliberately not a PR against upstream: the diff is spec artifacts, not
    # code, and it exists so a human can review the decomposition before work
    # packages are generated. Opening it upstream would put planning noise on a
    # public repo. Since the bot owns both sides it can merge or close freely —
    # and nothing downstream depends on the merge, because `pd generate-wp` reads
    # the local spec store rather than the branch.
    #
    # The fork is not a registry upstream, so refuse_canonical_push? passes it
    # straight through; `spec/<id>` is not a protected branch name either.
    # Idempotent: an already-open PR for this head is recorded and returned.
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

    # Where the `gh adopt` alias (one-time setup) is documented.
    ADOPT_DOC_URL = "https://github.com/opf/openproject-chomper#adopting-a-chomper-pr"

    # Fence around the bot-only preamble of a PR body. The `gh adopt` alias in
    # the README deletes this range verbatim, so these two lines are a published
    # interface: changing either string orphans every PR opened before the change
    # (an old PR's fence no longer matches the new alias, and vice versa), and
    # adoption then silently keeps the AI disclaimer on a maintainer's PR.
    BANNER_OPEN  = "<!-- chomper:banner -->"
    BANNER_CLOSE = "<!-- /chomper:banner -->"

    # Every chomper PR is opened cross-repo against upstream from the bot's fork,
    # which can't run secret-gated CI, so tell maintainers up front how to
    # re-publish it under their own account. The PR lives in the upstream repo, so
    # a bare number resolves against the maintainer's canonical checkout. The
    # number only exists after creation — hence the follow-up body edit.
    # Appended as the banner's second bullet, so it stays inside the fence
    # `gh adopt` deletes (an adopted PR must not tell its owner to adopt it).
    # Best-effort: a failed update just leaves the note off.
    def add_adopt_note(upstream, url, pr_body, banner)
      number = Clients::GitHub.pr_number_from_url(url)
      return unless number
      note = "* To ship the PR, first run `gh adopt #{number}` ([setup guide](#{ADOPT_DOC_URL})) " \
             "to make it yours."
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
        description: "chomper plan: #{wp_label(st.item_id)} — #{st.subject}",
        filename:    "wp-#{st.item_id}-plan.md",
        content:     st.plan_file.read
      )
      cache.write(url) if url
      url
    end
  end
end
