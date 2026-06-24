require "pathname"
require "rainbow"
require_relative "repo"

module Chomper
  FatalError = Class.new(StandardError)

  class Context
    attr_reader :script_dir, :state_dir, :progress_file,
                :log_file, :claude_url, :github_token,
                :state_container, :op_url, :token
    attr_reader   :allowed_op_user_ids, :allowed_gh_users

    def self.build(script_dir = nil)
      script_dir = Pathname(script_dir || File.expand_path("../../..", __FILE__))
      new(script_dir)
    end

    def initialize(script_dir)
      @script_dir         = Pathname(script_dir)
      @state_dir          = @script_dir / ".chomper"
      @progress_file      = @state_dir / "progress.txt"
      @log_file           = @state_dir / "chomp.log"
      @github_token       = ENV["GITHUB_TOKEN"]
      @claude_url         = ENV.fetch("CLAUDE_URL", "http://claude:47291")
      @state_container    = "/state"
      @op_url             = ENV["OPENPROJECT_URL"]
      @token              = ENV["OPENPROJECT_TOKEN"]
      # @chomper triggers are gated only when this list is non-empty; otherwise
      # every OpenProject user may trigger the agent. These are OpenProject user
      # ids (the number in a profile URL, /users/<id>), not emails: a non-admin
      # API token can't read other users' emails, but every comment carries its
      # author's user id in the activity's `_links.user.href`.
      @allowed_op_user_ids   = ENV.fetch("CHOMPER_ALLOWED_OP_USER_IDS", "")
                                  .split(",").map { |id| id.strip }.reject(&:empty?)
      # GitHub logins allowed to trigger `gh-agent` on a chomper PR. Unlike the
      # email allowlist, this defaults to a single user rather than "everyone" —
      # an open trigger on a public PR would let anyone push code to your branch.
      @allowed_gh_users      = ENV.fetch("CHOMPER_ALLOWED_GH_USERS", "thykel")
                                  .split(",").map { |u| u.strip.downcase.delete_prefix("@") }.reject(&:empty?)

      @state_dir.mkpath
      @progress_file.open("a") {} # touch
    end

    # The repo registry, loaded from repos.json. Lazy so teardown commands
    # (status/reset) don't pay for it and a malformed repos.json only fails the
    # modes that actually need a repo.
    def repos
      @repos ||= Registry.build(script_dir: @script_dir, state_dir: @state_dir)
    end

    # The repo used when a flow hasn't chosen one (the registry's first entry).
    def default_repo
      repos.default
    end

    def load_config!
      raise FatalError, "Config not found — add OPENPROJECT_URL and OPENPROJECT_TOKEN to .env and re-run." \
        unless @op_url && @token
      repos # build + validate the registry now, so a bad repos.json fails fast
    rescue Registry::Error => e
      raise FatalError, "Invalid repos.json — #{e.message}"
    end

    # Opt-in agent self-review of plans (default off). A human approves every plan
    # via `@chomper approve`, so the reviewer pass is redundant unless re-enabled.
    def plan_review?
      %w[1 true yes].include?(ENV["CHOMPER_PLAN_REVIEW"].to_s.strip.downcase)
    end

    # Auto-approve every plan instead of waiting for a human (default off). In
    # backlog/fix the terminal approval prompt resolves to "yes"; in agent mode a
    # planned WP is implemented immediately rather than waiting for `@chomper
    # approve`. Unattended — use with care.
    def auto_plan_approval?
      %w[1 true yes].include?(ENV["AUTO_PLAN_APPROVAL"].to_s.strip.downcase)
    end

    # PR delivery mode (`CHOMPER_PR_MODE`, default "fork"). When "direct", the
    # fix branch is pushed straight to the canonical repo and a same-repo PR is
    # opened — which requires the token to have push access to that repo, and
    # trades the fork's isolation for the protected-branch guard + human-gated
    # merge. The default "fork" path forks, pushes to the fork, and opens a
    # cross-repo PR, so the token never needs write access to the canonical repo.
    def direct_pr?
      ENV["CHOMPER_PR_MODE"].to_s.strip.downcase == "direct"
    end
  end
end
