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

      item_dir     = @ctx.state_dir / "items" / item_id.to_s
      pr_desc_file = item_dir / "pr.md"
      pr_url_file  = item_dir / "pr_url.txt"

      unless local_branch_exists?(worktree, branch)
        puts "  Error: branch #{branch} not found — has this item been committed?"
        return nil
      end
      unless pr_desc_file.exist? && pr_desc_file.size > 0
        puts "  Error: no PR description at #{pr_desc_file} (missing or empty)"
        return nil
      end

      existing = @github.find_open_pr(github_repo, branch: branch)
      if existing
        pr_url_file.write(existing)
        return existing
      end

      log_script "Publishing #{wp_label(item_id)} — #{subject}"

      # Point reviewers at the work package, where the plan and discussion live
      # as comments — a standalone section at the top so the link is never lost.
      wp_url  = "#{@ctx.op_url}/work_packages/#{item_id}"
      pr_body = "# Ticket\n#{wp_url}\n\n#{pr_desc_file.read}"

      @github.push_branch(github_repo, branch: branch, worktree_path: @ctx.worktree_host)

      title = "[#{wp_label(item_id)}] #{subject}"
      url = @github.create_draft_pr(github_repo, base: "dev", head: branch, title: title, body: pr_body)
      pr_url_file.write(url)
      record_progress(item_id, branch, "published")
      url
    end

    private

    def github_repo
      @github_repo ||= begin
        url = worktree.remote('origin').url
        url.match(%r{github\.com[:/](.+?)(?:\.git)?$})&.captures&.first ||
          raise("Could not determine GitHub repo from remote URL: #{url}")
      end
    end

  end
end
