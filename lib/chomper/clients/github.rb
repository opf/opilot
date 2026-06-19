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

      # Ensure the authenticated user's fork of `upstream` ("owner/repo") exists
      # and return its full name ("me/repo"). Idempotent: GitHub returns the
      # existing fork if one is already present, otherwise creates it. chomper
      # pushes branches to this fork and opens the PR against upstream, so the
      # token never needs write access to upstream itself.
      def ensure_fork(upstream)
        @octokit.fork(upstream).full_name
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

      # Fetches a branch's current head from GitHub into FETCH_HEAD, over HTTPS
      # with the credential helper — never the worktree's `origin`, which may be
      # an SSH remote (git@github.com:…) with no key/known_hosts in the
      # container, dropping git into an interactive host-key prompt. Read-only,
      # so unlike push_branch it needs no protected-branch guard.
      def fetch_branch(repo, branch:, worktree_path:)
        cred_helper = '!f() { echo username=x-access-token; echo "password=$CHOMPER_GH_TOKEN"; }; f'
        system(
          { "CHOMPER_GH_TOKEN" => @token },
          "git", "-C", worktree_path.to_s,
          "-c", "credential.helper=",           # clear any inherited helpers
          "-c", "credential.helper=#{cred_helper}",
          "fetch", "--no-tags", "https://github.com/#{repo}.git", branch
        ) or raise "git fetch failed for branch #{branch}"
      end

      # Returns the URL of an open PR on `base_repo` whose head is `head`
      # ("fork_owner:branch" for a cross-repo fork PR), or nil.
      def find_open_pr(base_repo, head:)
        prs = @octokit.pull_requests(base_repo, head: head, state: "open")
        prs.first&.html_url
      rescue Octokit::Error
        nil
      end

      # Creates a draft PR and returns its URL.
      def create_draft_pr(repo, base:, head:, title:, body:)
        pr = @octokit.create_pull_request(repo, base, head, title, body, draft: true)
        pr.html_url
      end

      # Fetch a pull request's metadata (used for the head branch and title).
      def pull_request(repo, number)
        @octokit.pull_request(repo, number)
      end

      # Comments in the PR's main conversation thread (the "issue" timeline).
      def issue_comments(repo, number)
        @octokit.issue_comments(repo, number)
      end

      # Inline review comments anchored to diff lines (a separate stream from the
      # conversation thread above). Includes findings from automated reviewers
      # such as GitHub Copilot.
      def review_comments(repo, number)
        @octokit.pull_request_comments(repo, number)
      end

      # Submitted reviews (the top-level review bodies + verdicts — e.g. Copilot's
      # review summary, a human's "changes requested"). Separate from the inline
      # review_comments above.
      def reviews(repo, number)
        @octokit.pull_request_reviews(repo, number)
      end

      # Post a comment to the PR's conversation thread; returns the new comment.
      def add_issue_comment(repo, number, body)
        @octokit.add_comment(repo, number, body)
      end

      # Reply to an inline review comment, keeping the reply in its thread;
      # returns the new comment.
      def reply_to_review_comment(repo, number, body, in_reply_to)
        @octokit.create_pull_request_comment_reply(repo, number, body, in_reply_to)
      end

      # The PR number embedded in a chomper-stored PR URL
      # ("https://github.com/owner/repo/pull/123" → 123), or nil.
      def self.pr_number_from_url(url)
        url.to_s[%r{/pull/(\d+)\b}, 1]&.to_i
      end

      # The "owner/repo" embedded in a PR URL, or nil.
      def self.repo_from_url(url)
        url.to_s[%r{github\.com/([^/]+/[^/]+)/pull/\d+}, 1]
      end
    end
  end
end
