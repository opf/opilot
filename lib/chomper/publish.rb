require "octokit"

module Chomper
  class Publish
    include Helpers

    def initialize(ctx, backlog)
      @ctx     = ctx
      @backlog = backlog
    end

    def run_publish_stage(ids = [])
      unless @ctx.github_token
        puts "  Error: GITHUB_TOKEN is not set — cannot publish PRs."
        return
      end
      if ids.any?
        ids.each { |id| publish_item(id) rescue puts("  Error publishing ##{id}: #{$!.message}") }
      else
        count = 0
        @backlog.committed.each do |item|
          publish_item(item["id"]) rescue puts("  Error publishing ##{item["id"]}: #{$!.message}")
          count += 1
        end
        puts "  Nothing committed yet — run ./chomper fix first." if count == 0
      end
    end

    private

    def publish_item(item_id)
      item = @backlog.find(item_id)
      unless item
        puts "  Error: ##{item_id} not found in backlog"
        return
      end

      branch       = branch_slug(item_id, item["subject"])
      pr_desc_file = @ctx.state_dir / "items" / item_id.to_s / "pr.md"

      unless local_branch_exists?(worktree, branch)
        puts "  Error: branch #{branch} not found — has this item been committed?"
        return
      end
      unless pr_desc_file.exist? && pr_desc_file.size > 0
        puts "  Error: no PR description at #{pr_desc_file} (missing or empty)"
        return
      end

      existing = existing_pr_url(branch)
      if existing
        puts "  PR already exists for #{branch}: #{existing} — skipping"
        (@ctx.state_dir / "items" / item_id.to_s / "pr_url.txt").write(existing)
        return
      end

      log_script "Publishing ##{item_id} — #{item["subject"]}"

      gist_url = upload_plan_gist(item_id, item["subject"])

      pr_body = pr_desc_file.read
      if gist_url
        pr_body = pr_body.sub(/^(##[^\n]*accomplish[^\n]*\n)/i) { "#{$1}\n**Plan:** #{gist_url}\n" }
      end

      push_url = "https://#{@ctx.github_token}@github.com/#{github_repo}.git"
      system("git", "-C", @ctx.worktree_host.to_s, "push", push_url, "#{branch}:#{branch}") or
        raise "git push failed for branch #{branch}"

      title = "[##{item_id}] #{item["subject"]}"
      pr = octokit.create_pull_request(
        github_repo, "dev", branch, title, pr_body,
        draft: true
      )
      puts "  ✓ #{pr.html_url}"
      (@ctx.state_dir / "items" / item_id.to_s / "pr_url.txt").write(pr.html_url)
      @ctx.progress_file.open("a") { |f| f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{item_id}|#{branch}|published" }
    end

    def upload_plan_gist(item_id, subject)
      gist_file = @ctx.state_dir / "items" / item_id.to_s / "gist.txt"
      return gist_file.read.chomp if gist_file.exist?

      plan_file = @ctx.state_dir / "items" / item_id.to_s / "plan.md"
      return nil unless plan_file.exist?

      gist = octokit.create_gist(
        description: "Bug chomper plan: ##{item_id} — #{subject}",
        public: false,
        files: { "wp-#{item_id}-plan.md" => { content: plan_file.read } }
      )
      gist_file.write(gist.html_url)
      puts "  ✓ Plan gist → #{gist.html_url}"
      gist.html_url
    rescue Octokit::Error => e
      puts "  Warning: could not create plan gist: #{e.message}"
      nil
    end

    def existing_pr_url(branch)
      owner = github_repo.split("/").first
      prs = octokit.pull_requests(github_repo, head: "#{owner}:#{branch}", state: "open")
      prs.first&.html_url
    rescue Octokit::Error
      nil
    end

    def worktree
      @worktree ||= Git.open(@ctx.worktree_host.to_s)
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
