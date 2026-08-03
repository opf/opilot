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
      #
      # Blank is normalised to nil, and that normalisation is load-bearing rather
      # than tidiness: every consumer asks "is there a token?" as truthiness
      # (`maintainer_token ? :maintainer : :contributor`, `contributor_token.nil?`,
      # `contributor_token || maintainer_token`), and compose.yml passes both as
      # `TOKEN=${TOKEN:-}` — so inside the container an unset token arrives as ""
      # , which is TRUTHY. Unnormalised, `ship` selected the maintainer identity
      # with no maintainer token: no fork, a push aimed at the canonical repo, and
      # `unless author_token` sailing past its own guard.
      @contributor_token  = presence(ENV["GITHUB_CONTRIBUTOR_TOKEN"])
      @maintainer_token   = presence(ENV["GITHUB_MAINTAINER_TOKEN"])
      @claude_url         = ENV.fetch("CLAUDE_URL", "http://claude:47291")
      @state_container    = "/state"
      # Normalised once here rather than at each call site: every consumer
      # appends its own path ("#{op_url}/api/v3/…", "#{op_url}/documents/…"),
      # so a trailing slash in .env turns all of them into "//…".
      @op_url             = ENV["OPENPROJECT_URL"]&.sub(%r{/+\z}, "")
      @token              = ENV["OPENPROJECT_TOKEN"]
      # @chomper triggers are gated only when this list is non-empty; otherwise
      # every OpenProject user may trigger the agent. These are OpenProject user
      # ids (the number in a profile URL, /users/<id>), not emails: a non-admin
      # API token can't read other users' emails, but every comment carries its
      # author's user id in the activity's `_links.user.href`.
      @allowed_op_user_ids   = ENV.fetch("CHOMPER_ALLOWED_OP_USER_IDS", "")
                                  .split(",").map { |id| id.strip }.reject(&:empty?)
      # GitHub logins allowed to trigger `gh-agent` on a chomper PR. Empty means
      # any GitHub user can trigger on chomper's own PRs (and disables upstream
      # PR scanning) — the setup wizard demands an explicit confirmation to run
      # the gh-agent modes that way, since an open trigger on a public PR would
      # let anyone push code to the bot's branch.
      @allowed_gh_users      = ENV.fetch("CHOMPER_ALLOWED_GH_USERS", "")
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

    # Act on chomper being set as a WP's assignee as if the assigner commented
    # `@chomper ship` (default on; set CHOMPER_ASSIGN_TRIGGER=0 to disable).
    # Assignment needs OpenProject's edit-work-package permission, but is not
    # gated by the comment allowlist — turn this off on instances where WP edit
    # rights are broad.
    def assign_trigger?
      !%w[0 false no off].include?(ENV["CHOMPER_ASSIGN_TRIGGER"].to_s.strip.downcase)
    end

    # Work-package type names the `pd` (product development) pipeline maps the
    # OpenSpec model onto: a change becomes one parent WP of the first type, and
    # each top-level tasks.md section becomes a child of the second. Neither is
    # a stock OpenProject type, so both are configurable and are resolved to ids
    # BY NAME at `pd init` (never hardcoded) — a missing type fails fast there
    # rather than surfacing as a confusing 422 two stages later.
    def pd_parent_type
      ENV.fetch("CHOMPER_PD_PARENT_TYPE", "FEATURE").strip
    end

    def pd_child_type
      ENV.fetch("CHOMPER_PD_CHILD_TYPE", "IMPLEMENTATION").strip
    end

    # The two statuses `pd implement` moves a work package through: one when the
    # implementation run starts, one when its draft PR is open. Named after the
    # pipeline's own meaning rather than any instance's wording, since the
    # defaults are stock OpenProject statuses that an instance may well have
    # renamed or dropped. Resolved by name from `pd init`'s status cache; an
    # empty value turns that transition off, and a name the instance doesn't
    # have is reported and skipped — a status is bookkeeping, never worth
    # failing an implementation over.
    def pd_implementing_status
      ENV.fetch("CHOMPER_PD_IMPLEMENTING_STATUS", "In progress").strip
    end

    def pd_implemented_status
      ENV.fetch("CHOMPER_PD_IMPLEMENTED_STATUS", "Developed").strip
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

    private

    # nil for a missing OR blank value, so callers can test one thing.
    def presence(value)
      value.to_s.strip.empty? ? nil : value.strip
    end
  end
end
