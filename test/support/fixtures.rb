require "tmpdir"

module OPilot
  # Fixtures shared by the runner and poller tests: one context builder over a
  # tmpdir, state dir and registry, carrying the union of the fields the runners
  # read. A test sets the few it cares about and leaves the rest at their
  # defaults.
  #
  # `FakeWorktree` deliberately stays with each test file. Those model different
  # git surfaces — merge conflicts, a dirty tree, branch creation — and one
  # double configurable enough to cover all of them would read worse than three.
  module TestFixtures
    # The context readers the runners call. `host` backs #op_host — the
    # per-instance namespace under work_packages/ — and op_url is derived from
    # it so the two can never disagree.
    Ctx = Struct.new(
      :script_dir, :state_dir, :state_container, :op_url, :token,
      :allowed_op_user_ids, :allowed_gh_users, :contributor_token,
      :log_file, :progress_file, :repos,
      :ignored_checks, :ci_max_attempts, :track_upstream, :host,
      keyword_init: true
    ) do
      def default_repo        = repos.default
      def op_host             = host
      def ci_ignored_checks   = ignored_checks || []
      def track_upstream_prs? = track_upstream
    end

    # A context over `tmpdir`, with its .opilot/ state dir created.
    #
    # `repos:` takes repos.json entries for a test that needs more than the one
    # synthesized openproject repo; without it Registry.build falls back to that
    # single entry. Any Ctx field can be overridden by keyword.
    def build_ctx(tmpdir, host: "op.example.com", repos: nil, **overrides)
      script_dir = Pathname(tmpdir)
      state_dir  = script_dir / ".opilot"
      state_dir.mkpath

      config = nil
      if repos
        config = script_dir / "repos.json"
        config.write(JSON.generate("summary" => "", "repos" => repos))
      end
      registry = Registry.build(script_dir: script_dir, state_dir: state_dir,
                                op_repo_path: tmpdir.to_s, config_path: config)

      Ctx.new(
        script_dir:      script_dir,
        state_dir:       state_dir,
        state_container: "/state",
        op_url:          "https://#{host}",
        token:           "tok",
        allowed_op_user_ids: [],
        allowed_gh_users:    [],
        contributor_token:   nil,
        log_file:        script_dir / "chomp.log",
        progress_file:   script_dir / "progress.txt",
        repos:           registry,
        ignored_checks:  [],
        ci_max_attempts: 5,
        track_upstream:  false,
        host:            host
      ).tap { |ctx| overrides.each { |k, v| ctx[k] = v } }
    end

    # ── git doubles ─────────────────────────────────────────────────────────
    #
    # The slice of the ruby-git surface Helpers reads back after a commit. No
    # test asserts on the fixed strings, so one set of defaults serves them all.

    class FakeCommit
      attr_reader :sha, :message, :date
      def initialize(sha: "abcdef1234567", message: "fix: something", date: Time.utc(2026, 1, 1))
        @sha = sha; @message = message; @date = date
      end
    end

    # A `git log` handle. #between is the "is this branch behind / does it carry
    # commits" query, which chains back to self so `.between(a, b).execute` works.
    class FakeLog
      def initialize(commits = []); @commits = Array(commits); end
      def between(_from, _to); self; end
      def execute; @commits; end
      def first; @commits.first; end
    end

    class FakeDiff
      PATCH = "diff --git a/app/x.rb b/app/x.rb\n+  return if total.nil?\n".freeze

      def initialize(has_changes); @has_changes = has_changes; end
      def entries; @has_changes ? [:change] : []; end
      def stats; { files: { "app/x.rb" => { insertions: 2, deletions: 1 } } }; end
      def patch; PATCH; end
    end
  end
end
