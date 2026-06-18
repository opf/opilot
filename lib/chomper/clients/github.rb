require "octokit"

module Chomper
  module Clients
    # GitHub API client. All GitHub interactions live here — REST calls via
    # Octokit and branch pushes via git; callers never touch Octokit or
    # construct GitHub URLs directly.
    class GitHub
      # Branches the runner must never push to, regardless of what a work
      # package's type/title produces. `dev` and `release*` are deploy targets;
      # a fix branch always looks like `bug/<id>-<slug>`, so a push to one of
      # these can only be a bug or a crafted WP and is refused outright.
      def self.protected_branch?(branch)
        branch == "dev" || branch.start_with?("release")
      end

      def initialize(token)
        @token   = token
        @octokit = Octokit::Client.new(access_token: token)
      end

      # Pushes a local branch to GitHub. Authenticates via a credential helper
      # so the token never appears in argv (visible via ps/proc).
      def push_branch(repo, branch:, worktree_path:)
        if self.class.protected_branch?(branch)
          raise "Refusing to push to protected branch #{branch.inspect}"
        end

        cred_helper = '!f() { echo username=x-access-token; echo "password=$CHOMPER_GH_TOKEN"; }; f'
        system(
          { "CHOMPER_GH_TOKEN" => @token },
          "git", "-C", worktree_path.to_s,
          "-c", "credential.helper=",           # clear any inherited helpers
          "-c", "credential.helper=#{cred_helper}",
          "push", "https://github.com/#{repo}.git", "#{branch}:#{branch}"
        ) or raise "git push failed for branch #{branch}"
      end

      # Returns the URL of an open PR for the given head branch, or nil.
      def find_open_pr(repo, branch:)
        owner = repo.split("/").first
        prs = @octokit.pull_requests(repo, head: "#{owner}:#{branch}", state: "open")
        prs.first&.html_url
      rescue Octokit::Error
        nil
      end

      # Creates a draft PR and returns its URL.
      def create_draft_pr(repo, base:, head:, title:, body:)
        pr = @octokit.create_pull_request(repo, base, head, title, body, draft: true)
        pr.html_url
      end
    end
  end
end
