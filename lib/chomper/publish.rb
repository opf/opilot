require_relative "clients"

module Chomper
  class Publish
    include Helpers

    # `as` is the publishing identity. :contributor (the default) is the bot
    # account: it forks the upstream, pushes there, and opens a cross-repo draft
    # PR — the agent loops always publish this way. :maintainer is an account
    # with push access: the branch goes straight to the canonical repo and a
    # same-repo draft PR is opened, every push gated on an interactive yes.
    def initialize(ctx, as: :contributor)
      @ctx    = ctx
      @as     = as
      @github = Clients::GitHub.new(author_token)
    end

    # The token of the identity this publisher acts as — also the author
    # identity adopted for commits, so a PR's commits match its opener.
    def author_token
      contributor? ? @ctx.contributor_token : @ctx.maintainer_token
    end

    # Push the WP's fix branch in `repo` and open a draft PR there, returning the
    # PR URL (or nil on failure). Idempotent: an already-open PR is recorded and
    # returned. Upstream, base branch, and worktree all come from `repo`, so a WP
    # that spans several repos opens an independent PR in each.
    def open_pr(item_id, subject, branch, repo)
      unless author_token
        puts "  Error: #{contributor? ? "GITHUB_CONTRIBUTOR_TOKEN" : "GITHUB_MAINTAINER_TOKEN"} is not set — cannot open PRs."
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

      # As the contributor the branch goes to the bot's fork and the PR is
      # opened against upstream with a cross-repo head ("fork_owner:branch"),
      # keeping the token off the canonical repo. As the maintainer the branch
      # is pushed straight to upstream and a same-repo PR is opened — the token
      # needs push access there, and maintainer-edits must be disabled (GitHub
      # 422s on a same-repo PR). Either way the head is "owner:branch".
      target_repo = contributor? ? @github.ensure_fork(upstream) : upstream
      head        = "#{target_repo.split('/').first}:#{branch}"

      existing = @github.find_open_pr(upstream, head: head)
      if existing
        pr_url_file.write(existing)
        return existing
      end

      log_script "Publishing #{wp_label(item_id)} → #{repo.name} (base #{base}, as #{@as}) — #{subject}"

      # Keep the PR body compact; attach the full plan as a (secret) gist and
      # link it under the banner for anyone who wants to read deeper.
      banner    = "🤖 AI-generated PR. Chat with @#{@github.login} for any further adjustments."
      gist_url  = plan_gist_url(st)
      plan_line = gist_url ? "📋 **Implementation plan:** #{gist_url}\n\n" : ""
      pr_body   = "#{banner}\n\n#{plan_line}#{pr_desc_file.read}"

      unless confirm_canonical_push?(target_repo, branch)
        puts "  Push declined — #{branch} was not pushed and no PR was opened."
        return nil
      end
      @github.push_branch(target_repo, branch: branch, worktree_path: repo.worktree_host)

      title = pr_title(item_id, subject)
      url = @github.create_draft_pr(upstream, base: base, head: head, title: title, body: pr_body,
                                    maintainer_can_modify: contributor?)
      add_overtake_note(upstream, url, pr_body, banner) if contributor?
      pr_url_file.write(url)
      record_progress(item_id, branch, "published:#{repo.name}")
      url
    end

    private

    def contributor?
      @as == :contributor
    end

    # Where the `gh overtake` alias (one-time setup) is documented.
    OVERTAKE_DOC_URL = "https://github.com/opf/openproject-chomper#taking-over-a-chomper-pr"

    # Fork PRs can't run secret-gated CI, so tell maintainers up front how to
    # re-publish this PR under their own account. The note names the concrete
    # PR number, which only exists after creation — hence the follow-up body
    # edit. Best-effort: a failed update just leaves the note off.
    def add_overtake_note(upstream, url, pr_body, banner)
      number = Clients::GitHub.pr_number_from_url(url)
      return unless number
      note = "🔁 Maintainers: [Run](#{OVERTAKE_DOC_URL}) `gh overtake #{number}` " \
             "to re-publish this PR under your own account."
      @github.update_pr_body(upstream, number, pr_body.sub(banner, "#{banner}\n#{note}"))
    rescue => e
      log_script "Could not add the overtake note to #{url}: #{e.message}"
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
