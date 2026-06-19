require_relative "clients"

module Chomper
  class Publish
    include Helpers

    def initialize(ctx)
      @ctx    = ctx
      @github = Clients::GitHub.new(ctx.github_token)
    end

    # Push the WP's fix branch and open a draft PR, returning the PR URL (or nil
    # on failure). Idempotent: an already-open PR is recorded and returned.
    def open_pr(item_id, subject, branch)
      unless @ctx.github_token
        puts "  Error: GITHUB_TOKEN is not set — cannot open PRs."
        return nil
      end

      item_dir     = Helpers.item_dir(@ctx, item_id)
      pr_desc_file = item_dir / "pr.md"
      pr_url_file  = item_dir / "pr_url.txt"

      unless local_branch_exists?(worktree, branch)
        puts "  Error: branch #{branch} not found — has this item been committed?"
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
      target_repo = @ctx.direct_pr? ? upstream_repo : @github.ensure_fork(upstream_repo)
      head        = "#{target_repo.split('/').first}:#{branch}"

      existing = @github.find_open_pr(upstream_repo, head: head)
      if existing
        pr_url_file.write(existing)
        return existing
      end

      log_script "Publishing #{wp_label(item_id)} — #{subject}"

      banner  = "🤖 AI-generated PR! Please review it for accuracy and then remove this line."
      pr_body = "#{banner}\n\n#{pr_desc_file.read}"

      @github.push_branch(target_repo, branch: branch, worktree_path: @ctx.worktree_host)

      title = pr_title(item_id, subject)
      url = @github.create_draft_pr(upstream_repo, base: "dev", head: head, title: title, body: pr_body,
                                    maintainer_can_modify: !@ctx.direct_pr?)
      pr_url_file.write(url)
      record_progress(item_id, branch, "published")
      url
    end

    private

    # The canonical repo the PR targets, derived from the worktree's origin
    # remote (chomper's worktree is checked out from the product clone).
    def upstream_repo
      @upstream_repo ||= begin
        url = worktree.remote('origin').url
        url.match(%r{github\.com[:/](.+?)(?:\.git)?$})&.captures&.first ||
          raise("Could not determine GitHub repo from remote URL: #{url}")
      end
    end

  end
end
