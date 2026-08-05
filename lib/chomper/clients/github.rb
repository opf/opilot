require "octokit"
require "faraday"
require "retriable"
require "open-uri"

module Chomper
  module Clients
    # GitHub API client. All GitHub interactions live here — REST calls via
    # Octokit and branch pushes via git; callers never touch Octokit or
    # construct GitHub URLs directly.
    class GitHub
      # Transient failures worth a retry on idempotent (GET) calls: a dropped,
      # refused, or timed-out connection — Octokit/Faraday wrap the underlying
      # EOFError/Errno as these — plus GitHub's own 5xx and rate-limit
      # responses. A 4xx (Octokit::ClientError) is a real answer, not a blip, so
      # it is deliberately excluded. Mirrors Clients::HTTP's policy for the
      # Net::HTTP path; note faraday-retry's own defaults do NOT include
      # Faraday::ConnectionFailed, which is exactly the "end of file reached"
      # case that otherwise crashes a long-running poll.
      RETRYABLE = [
        Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError,
        Octokit::ServerError, Octokit::TooManyRequests
      ].freeze

      # Retry tuning, overridable so the test suite can disable real sleeps
      # (see test/test_helper.rb), exactly as Clients::HTTP does.
      @max_tries     = 3
      @base_interval = 2
      class << self
        attr_accessor :max_tries, :base_interval
      end
      # Branches the runner must never push to, regardless of what a work
      # package's type/title produces. These are the base/deploy branches across
      # every product repo chomper targets (`dev` for openproject, `main`/`master`
      # for the satellite repos) plus `release*`. A fix branch always looks like
      # `bug/<id>-<slug>`, so a push to one of these can only be a bug or a crafted
      # WP and is refused outright — a static superset of the registry's bases, so
      # the guard needs no registry to stay correct.
      PROTECTED_BRANCHES = %w[dev main master].freeze

      def self.protected_branch?(branch)
        PROTECTED_BRANCHES.include?(branch) || branch.start_with?("release")
      end

      def initialize(token)
        @token   = token
        @octokit = Octokit::Client.new(access_token: token)
      end

      # Run an idempotent Octokit call, retrying transient network/5xx/rate-limit
      # failures a few times before giving up. Only safe to wrap GETs: a retried
      # POST could double-create a comment or PR if the first attempt actually
      # landed before the connection dropped, so writes are left to fail and be
      # handled by the caller's loop guard.
      def with_retry
        Retriable.retriable(
          on: RETRYABLE, tries: self.class.max_tries,
          base_interval: self.class.base_interval, multiplier: 2.0,
          on_retry: proc { |e, try, _, next_interval|
            wait = next_interval ? " — retrying in #{next_interval.round}s…" : ""
            warn "  ⚠ GitHub #{e.class} (attempt #{try})#{wait}"
          }
        ) { yield }
      end

      # Run a block with Octokit auto-pagination on, restoring it afterwards.
      # Octokit defaults auto_paginate to false, so list endpoints return only the
      # first page; CI calls must see every page to read a commit's full status.
      # Scoped per-call so other callers keep the cheaper single-page behaviour.
      def paginated
        prev = @octokit.auto_paginate
        @octokit.auto_paginate = true
        yield
      ensure
        @octokit.auto_paginate = prev
      end

      # Ensure the authenticated account's fork of `upstream` ("owner/repo")
      # exists and return its full name ("me/repo"). Idempotent: GitHub returns
      # the existing fork if one is already present, otherwise creates it.
      # chomper pushes branches to this fork and opens the PR against upstream,
      # so the token never needs write access to upstream itself.
      #
      # Forking is asynchronous: on first creation the repo may not be pushable
      # for a moment, so we wait until the API reports it exists before returning.
      def ensure_fork(upstream)
        full_name = @octokit.fork(upstream).full_name
        10.times do
          break if @octokit.repository?(full_name)
          sleep 1
        end
        full_name
      end

      # Fast-forward a fork's branch to its upstream — the API behind GitHub's
      # "Sync fork" button (no Octokit helper, hence the raw POST). Returns true
      # when the fork is (now) level.
      #
      # A fork's branch is frozen at fork-creation time while chomper's clones
      # track upstream, so without this a PR opened inside the fork shows every
      # intervening upstream commit as if the change had made them. Non-fatal: a
      # genuinely diverged branch 409s and the caller carries on, since a noisy PR
      # beats no PR.
      def sync_fork_branch(fork, branch:)
        with_retry { @octokit.post("/repos/#{fork}/merge-upstream", branch: branch) }
        true
      rescue Octokit::Error => e
        warn "  ⚠ Could not sync #{fork}'s #{branch} with upstream (#{e.class}) — " \
             "the PR diff may include unrelated upstream commits."
        false
      end

      # The bot account's git identity, as [name, email], for authoring commits.
      # Uses GitHub's no-reply email (`<id>+<login>@users.noreply.github.com`) so
      # commits attribute to the bot account and the operator's address is never
      # exposed on a public PR.
      def author_identity
        u = with_retry { @octokit.user }
        ["#{u.name || u.login}", "#{u.id}+#{u.login}@users.noreply.github.com"]
      end

      # The authenticated account's login (the bot's username), memoized — used
      # to recognise an @-mention of the bot itself as a trigger.
      def login
        @login ||= with_retry { @octokit.user }.login
      end

      # The classic-PAT scopes this token carries, from the X-OAuth-Scopes header
      # on a /user call. Empty for a fine-grained token (which has no such
      # header) and empty on failure — so callers must treat empty as "unknown",
      # never as "no permissions".
      def token_scopes
        with_retry { @octokit.scopes }
      rescue StandardError
        []
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
        prs = with_retry { @octokit.pull_requests(base_repo, head: head, state: "open") }
        prs.first&.html_url
      rescue Octokit::Error, Faraday::Error
        nil
      end

      # Create a gist and return its html_url, or nil on failure (e.g. the token
      # lacks the `gist` scope). Secret by default: unlisted and unindexed, but
      # readable by anyone with the link — used to attach a WP's full plan to its
      # PR while keeping the PR body itself compact.
      def create_gist(description:, filename:, content:, public: false)
        @octokit.create_gist(
          description: description, public: public,
          files: { filename => { content: content } }
        ).html_url
      rescue Octokit::Error, Faraday::Error => e
        warn "  Warning: could not create plan gist: #{e.message}"
        nil
      end

      # Creates a draft PR and returns its URL. `maintainer_can_modify` lets
      # anyone with push access to the base repo push to the PR's branch in the
      # fork ("Allow edits by maintainers") — so opf maintainers can take the PR
      # over. Only works because the fork is a personal (user) account, and must
      # be false for a same-repo (direct-mode) PR: GitHub rejects the flag with a
      # 422 when head and base live in the same repository.
      def create_draft_pr(repo, base:, head:, title:, body:, maintainer_can_modify: true)
        pr = @octokit.create_pull_request(
          repo, base, head, title, body, draft: true, maintainer_can_modify: maintainer_can_modify
        )
        pr.html_url
      end

      # Fetch a pull request's metadata (used for the head branch and title).
      def pull_request(repo, number)
        with_retry { @octokit.pull_request(repo, number) }
      end

      # Replace a PR's description (used to slot in content that needs the PR
      # number, which only exists after creation — e.g. the adopt note).
      def update_pr_body(repo, number, body)
        with_retry { @octokit.update_pull_request(repo, number, body: body) }
      end

      # Search PRs across GitHub (PRs are issues in the search API). `query` is a
      # GitHub search string, e.g. `repo:opf/openproject is:pr is:open "@chomper"
      # updated:>=2026-06-01`. Returns the matching items (capped to the first
      # page); empty on any search error so one bad query never breaks a poll.
      def search_prs(query, per_page: 50)
        with_retry { @octokit.search_issues(query, per_page: per_page) }.items
      rescue Octokit::Error, Faraday::Error
        []
      end

      # Comments in the PR's main conversation thread (the "issue" timeline).
      def issue_comments(repo, number)
        with_retry { @octokit.issue_comments(repo, number) }
      end

      # Inline review comments anchored to diff lines (a separate stream from the
      # conversation thread above). Includes findings from automated reviewers
      # such as GitHub Copilot.
      def review_comments(repo, number)
        with_retry { @octokit.pull_request_comments(repo, number) }
      end

      # Submitted reviews (the top-level review bodies + verdicts — e.g. Copilot's
      # review summary, a human's "changes requested"). Separate from the inline
      # review_comments above.
      def reviews(repo, number)
        with_retry { @octokit.pull_request_reviews(repo, number) }
      end

      # Post a comment to the PR's conversation thread; returns the new comment.
      def add_issue_comment(repo, number, body)
        @octokit.add_comment(repo, number, body)
      end

      # Post a review carrying inline `suggestion` comments on a PR chomper does
      # not own (`event: COMMENT` — chomper never approves or blocks). `comments`
      # is an array of {path:, line:, side:, body:} hashes (optionally
      # start_line:/start_side: for a multi-line range); each body wraps a
      # ```suggestion block the author applies with one click, landing as their
      # own commit. Anchored to `commit_id` (the reviewed head SHA) so the lines
      # resolve against the diff chomper actually read. No push access needed.
      def create_review(repo, number, commit_id:, body:, comments:)
        with_retry do
          @octokit.create_pull_request_review(
            repo, number, commit_id: commit_id, event: "COMMENT", body: body, comments: comments
          )
        end
      end

      # Reply to an inline review comment, keeping the reply in its thread;
      # returns the new comment.
      def reply_to_review_comment(repo, number, body, in_reply_to)
        @octokit.create_pull_request_comment_reply(repo, number, body, in_reply_to)
      end

      # Add an emoji reaction (default 👀) to a PR comment, acknowledging that
      # chomper saw it before it starts working. `kind` is :issue (conversation
      # thread) or :review (inline diff comment) — they live on different
      # endpoints. Best-effort: a failed reaction must never block handling.
      def react(repo, comment_id, kind:, content: "eyes")
        if kind == :review
          @octokit.create_pull_request_review_comment_reaction(repo, comment_id, content)
        else
          @octokit.create_issue_comment_reaction(repo, comment_id, content)
        end
      rescue Octokit::Error, Faraday::Error
        nil
      end

      # ── CI: check runs, annotations, and workflow-job logs ──────────────────
      # All used only by gh-agent's CI-fix path (chomper's own PRs). Each returns
      # an empty/nil result on an Octokit error so one flaky CI lookup never
      # breaks a poll.

      # Every check run reported for a commit (head SHA), with status/conclusion,
      # name, id, and output summary. The unified Checks API covers GitHub Actions
      # and most third-party CI. Fully paginated: Octokit's auto_paginate is off by
      # default, so without this a commit with >30 checks (OpenProject easily has
      # that) would be silently truncated to the first page — dropping failures or
      # mis-reading the commit as green.
      def check_runs(repo, ref)
        with_retry { paginated { @octokit.check_runs_for_ref(repo, ref, per_page: 100).check_runs } }
      rescue Octokit::Error, Faraday::Error
        []
      end

      # A check run's annotations (file/line/message) — what lint and most test
      # problem-matchers surface as. Skipped when a check has none.
      def check_run_annotations(repo, check_run_id)
        with_retry { @octokit.check_run_annotations(repo, check_run_id) }
      rescue Octokit::Error, Faraday::Error
        []
      end

      # The Actions workflow runs for a commit (head SHA) — the entry point for
      # reaching the failed jobs' logs.
      def workflow_runs(repo, head_sha)
        with_retry { paginated { @octokit.repository_workflow_runs(repo, head_sha: head_sha, per_page: 100).workflow_runs } }
      rescue Octokit::Error, Faraday::Error
        []
      end

      # The jobs of a workflow run (each with name/status/conclusion/id).
      def workflow_run_jobs(repo, run_id)
        with_retry { paginated { @octokit.workflow_run_jobs(repo, run_id, per_page: 100).jobs } }
      rescue Octokit::Error, Faraday::Error
        []
      end

      # The plain-text log of a single failed job, trimmed to its tail (the
      # failing section is at the end). `workflow_run_job_logs` returns a
      # short-lived redirect URL to blob storage; we fetch it and keep the last
      # `tail` lines, byte-capped so a runaway log can't blow up the prompt.
      def job_log(repo, job_id, tail: 400, max_bytes: 50_000)
        url = with_retry { @octokit.workflow_run_job_logs(repo, job_id) }
        return nil unless url
        text = URI.open(url, &:read).to_s
        text = (text.byteslice(-max_bytes..) || text) if text.bytesize > max_bytes
        text.scrub.lines.last(tail).join
      rescue StandardError
        nil
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
