require "octokit"

module Chomper
  class Publish
    include Helpers

    def initialize(ctx)
      @ctx = ctx
    end

    # Push the WP's fix branch and open a draft PR, returning the PR URL (or nil
    # on failure). Idempotent: an already-open PR is recorded and returned.
    def open_pr(item_id, subject)
      unless @ctx.github_token
        puts "  Error: GITHUB_TOKEN is not set — cannot open PRs."
        return nil
      end

      branch       = branch_slug(item_id, subject)
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

      existing = existing_pr_url(branch)
      if existing
        pr_url_file.write(existing)
        return existing
      end

      log_script "Publishing ##{item_id} — #{subject}"

      # Point reviewers at the work package, where the plan and discussion live as
      # comments. Inject it under the template's "accomplish" heading when present,
      # otherwise prepend it so the link is never lost.
      wp_url = "#{@ctx.op_url}/work_packages/#{item_id}"
      ref    = "**Work package:** #{wp_url} — plan & discussion in the comments."
      body   = pr_desc_file.read
      pr_body = if body.match?(/^##[^\n]*accomplish[^\n]*$/i)
                  body.sub(/^(##[^\n]*accomplish[^\n]*\n)/i) { "#{$1}\n#{ref}\n" }
                else
                  "#{ref}\n\n#{body}"
                end

      # Authenticate via a credential helper that reads the token from the child's
      # environment, so the secret never appears in argv (visible via ps/proc).
      push_url    = "https://github.com/#{github_repo}.git"
      cred_helper = '!f() { echo username=x-access-token; echo "password=$CHOMPER_GH_TOKEN"; }; f'
      system(
        { "CHOMPER_GH_TOKEN" => @ctx.github_token },
        "git", "-C", @ctx.worktree_host.to_s,
        "-c", "credential.helper=",            # reset any inherited helpers
        "-c", "credential.helper=#{cred_helper}",
        "push", push_url, "#{branch}:#{branch}"
      ) or raise "git push failed for branch #{branch}"

      title = "[##{item_id}] #{subject}"
      pr = octokit.create_pull_request(github_repo, "dev", branch, title, pr_body, draft: true)
      pr_url_file.write(pr.html_url)
      record_progress(item_id, branch, "published")
      pr.html_url
    end

    private

    def existing_pr_url(branch)
      owner = github_repo.split("/").first
      prs = octokit.pull_requests(github_repo, head: "#{owner}:#{branch}", state: "open")
      prs.first&.html_url
    rescue Octokit::Error
      nil
    end

    def github_repo
      @github_repo ||= begin
        url = worktree.remote('origin').url
        url.match(%r{github\.com[:/](.+?)(?:\.git)?$})&.captures&.first ||
          raise("Could not determine GitHub repo from remote URL: #{url}")
      end
    end

    def octokit
      @octokit ||= Octokit::Client.new(access_token: @ctx.github_token)
    end
  end
end
