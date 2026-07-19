require "pathname"
require "rainbow"
require "uri"
require_relative "repo"

module Chomper
  FatalError = Class.new(StandardError)

  class Context
    attr_reader :script_dir, :state_dir, :progress_file,
                :log_file, :claude_url, :contributor_token, :maintainer_token,
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
      # Two GitHub identities, and the command determines which one acts:
      # the CONTRIBUTOR is the dedicated bot account (no access to the canonical
      # repos — it forks, pushes to its fork, opens cross-repo draft PRs; the
      # agent loops always publish as it), the MAINTAINER is an account with
      # push access (script `ship`/`pr` publish as it by default: direct pushes
      # to the canonical repo, each gated on an interactive yes).
      @contributor_token  = ENV["GITHUB_CONTRIBUTOR_TOKEN"]
      @maintainer_token   = ENV["GITHUB_MAINTAINER_TOKEN"]
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

    # A filesystem-safe segment naming the OpenProject instance, derived from
    # OPENPROJECT_URL. Per-instance state (work packages, saved filters) is
    # namespaced under it so that pointing chomper at a different instance can't
    # collide — WP #42 on instance A is a different WP than #42 on instance B.
    # Keeps dots for readability ("community.openproject.org") and folds in a
    # non-default port so two local instances (":8080" vs ":9090") don't clash.
    def op_host
      @op_host ||= begin
        uri  = URI(@op_url.to_s)
        host = uri.host || @op_url.to_s
        seg  = uri.port && ![80, 443].include?(uri.port) ? "#{host}_#{uri.port}" : host
        s = seg.downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/\A-+|-+\z/, "")
        s.empty? ? "unknown-host" : s
      end
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

    # Act on chomper being set as a WP's assignee as if the assigner commented
    # `@chomper fix` (default on; set CHOMPER_ASSIGN_TRIGGER=0 to disable).
    # Assignment needs OpenProject's edit-work-package permission, but is not
    # gated by the comment allowlist — turn this off on instances where WP edit
    # rights are broad.
    def assign_trigger?
      !%w[0 false no off].include?(ENV["CHOMPER_ASSIGN_TRIGGER"].to_s.strip.downcase)
    end

    # Auto-approve every plan instead of waiting for a human (default off). In
    # fix/plan the terminal approval prompt resolves to "yes"; in agent mode a
    # planned WP is implemented immediately rather than waiting for `@chomper
    # approve`. Unattended — use with care.
    def auto_plan_approval?
      %w[1 true yes].include?(ENV["AUTO_PLAN_APPROVAL"].to_s.strip.downcase)
    end

    # How many times gh-agent will chase a single PR's CI before giving up and
    # asking for a human (`CHOMPER_CI_MAX_ATTEMPTS`, default 5, floored at 1).
    def ci_max_attempts
      [ENV.fetch("CHOMPER_CI_MAX_ATTEMPTS", "5").to_i, 1].max
    end

    # Check-run names gh-agent should ignore when reading a PR's CI status
    # (`CHOMPER_CI_IGNORE_CHECKS`, comma-separated, case-insensitive). For checks
    # chomper can't fix — e.g. "SaaS tests", which needs secrets a fork PR can't
    # access, so it always fails — chasing them just burns attempts. Defaults to
    # "SaaS tests"; set to empty to ignore none.
    def ci_ignored_checks
      ENV.fetch("CHOMPER_CI_IGNORE_CHECKS", "SaaS tests")
         .split(",").map { |s| s.strip.downcase }.reject(&:empty?)
    end
  end
end
