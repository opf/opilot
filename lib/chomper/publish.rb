require_relative "clients"

module Chomper
  class Publish
    include Helpers

    def initialize(ctx)
      @ctx    = ctx
      @github = Clients::GitHub.new(ctx.github_token)
    end

    # Push the WP's fix branch in `repo` and open a draft PR there, returning the
    # PR URL (or nil on failure). Idempotent: an already-open PR is recorded and
    # returned. Upstream, base branch, and worktree all come from `repo`, so a WP
    # that spans several repos opens an independent PR in each.
    def open_pr(item_id, subject, branch, repo)
      unless @ctx.github_token
        puts "  Error: GITHUB_TOKEN is not set — cannot open PRs."
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

      # In the default "fork" mode the branch goes to the bot's fork and the PR
      # is opened against upstream with a cross-repo head ("fork_owner:branch"),
      # keeping the token off the canonical repo. In "direct" mode the branch is
      # pushed straight to upstream and a same-repo PR is opened — the token
      # needs push access there, and maintainer-edits must be disabled (GitHub
      # 422s on a same-repo PR). Either way the head is "owner:branch".
      target_repo = @ctx.direct_pr? ? upstream : @github.ensure_fork(upstream)
      head        = "#{target_repo.split('/').first}:#{branch}"

      existing = @github.find_open_pr(upstream, head: head)
      if existing
        pr_url_file.write(existing)
        return existing
      end

      log_script "Publishing #{wp_label(item_id)} → #{repo.name} (base #{base}) — #{subject}"

      banner  = "🤖 AI-generated PR! Please review it for accuracy and then remove this line."
      pr_body = "#{banner}\n\n#{pr_desc_file.read}"

      @github.push_branch(target_repo, branch: branch, worktree_path: repo.worktree_host)

      title = pr_title(item_id, subject)
      url = @github.create_draft_pr(upstream, base: base, head: head, title: title, body: pr_body,
                                    maintainer_can_modify: !@ctx.direct_pr?)
      pr_url_file.write(url)
      record_progress(item_id, branch, "published:#{repo.name}")
      url
    end

  end
end
