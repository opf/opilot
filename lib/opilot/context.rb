require "pathname"
require "rainbow"
require "uri"
require_relative "repo"

module OPilot
  FatalError = Class.new(StandardError)

  class Context
    attr_reader :script_dir, :state_dir, :progress_file,
                :log_file, :harness_url, :contributor_token,
                :state_container, :op_url, :token,
                :authgw_url, :gw_token, :inference_url, :opgw_url
    attr_reader   :allowed_op_user_ids, :allowed_gh_users

    def self.build(script_dir = nil)
      script_dir = Pathname(script_dir || File.expand_path("../../..", __FILE__))
      new(script_dir)
    end

    def initialize(script_dir)
      @script_dir         = Pathname(script_dir)
      @state_dir          = @script_dir / ".opilot"
      @progress_file      = @state_dir / "progress.txt"
      @log_file           = @state_dir / "chomp.log"
      # opilot's one GitHub identity: the CONTRIBUTOR, a dedicated bot account
      # with no access to the canonical repos. It forks, pushes to its fork, and
      # opens cross-repo draft PRs — every mode publishes this way, so a
      # maintainer's merge is always the gate.
      #
      # Blank is normalised to nil, and that normalisation is load-bearing rather
      # than tidiness: consumers ask "is there a token?" as truthiness, and
      # compose.yml passes the token as `TOKEN=${TOKEN:-}` — so inside the
      # container an unset token arrives as "", which is TRUTHY.
      @contributor_token  = presence(ENV["GITHUB_CONTRIBUTOR_TOKEN"])
      @harness_url        = ENV.fetch("HARNESS_URL", "http://harness:47291")
      # authgw is the only sidecar holding the real inference key; `usage`
      # queries it for account/key balance the same non-secret way pi does —
      # a Bearer OPILOT_GW_TOKEN, never the real key. nil (not "") when unset,
      # so `usage` can tell "not running via ./opilot" from "token is blank".
      @authgw_url         = ENV.fetch("AUTHGW_URL", "http://authgw:47292")
      @gw_token           = presence(ENV["OPILOT_GW_TOKEN"])
      # Which upstream authgw forwards to. The runner never calls it directly —
      # this is for reporting, so `usage` can name the endpoint it is (or is
      # not) reading spend from. The default keeps an untouched .env on
      # OpenRouter.
      # presence(), not ENV.fetch with a default: compose passes this through
      # as a bare `- VAR`, and ./opilot exports it as "" when .env doesn't set
      # it. An empty string beats a fetch default and would print a blank
      # upstream.
      @inference_url      = presence(ENV["OPILOT_INFERENCE_URL"]) || "https://openrouter.ai/api/v1"
      # The OpenProject MCP gateway (see MCP.md). nil (not a hardcoded default)
      # when unset: `./opilot` exports this only when both the harness and
      # OPILOT_OP_MCP are needed, and an absent value is what tells
      # #report_op_mcp_status to say so rather than try to connect nowhere.
      @opgw_url           = presence(ENV["OPILOT_OPGW_URL"])
      @state_container    = "/state"
      # Normalised once here rather than at each call site: every consumer
      # appends its own path ("#{op_url}/api/v3/…", "#{op_url}/documents/…"),
      # so a trailing slash in .env turns all of them into "//…".
      @op_url             = ENV["OPENPROJECT_URL"]&.sub(%r{/+\z}, "")
      @token              = ENV["OPENPROJECT_TOKEN"]
      # @opilot triggers are gated only when this list is non-empty; otherwise
      # every OpenProject user may trigger the agent. These are OpenProject user
      # ids (the number in a profile URL, /users/<id>), not emails: a non-admin
      # API token can't read other users' emails, but every comment carries its
      # author's user id in the activity's `_links.user.href`.
      @allowed_op_user_ids   = ENV.fetch("OPILOT_ALLOWED_OP_USER_IDS", "")
                                  .split(",").map { |id| id.strip }.reject(&:empty?)
      # GitHub logins allowed to trigger `gh-agent` on a opilot PR. Empty means
      # any GitHub user can trigger on opilot's own PRs (and disables upstream
      # PR scanning) — the setup wizard demands an explicit confirmation to run
      # the gh-agent modes that way, since an open trigger on a public PR would
      # let anyone push code to the bot's branch.
      @allowed_gh_users      = ENV.fetch("OPILOT_ALLOWED_GH_USERS", "")
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
    # namespaced under it so that pointing opilot at a different instance can't
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

    # Just the OpenProject credentials. Split out so `op`, which resolves no
    # clone, is not killed by a repos.json it never reads.
    def load_openproject_config!
      raise FatalError, "Config not found — add OPENPROJECT_URL and OPENPROJECT_TOKEN to .env and re-run." \
        unless @op_url && @token
    end

    def load_config!
      load_openproject_config!
      repos # build + validate the registry now, so a bad repos.json fails fast
    rescue Registry::Error => e
      raise FatalError, "Invalid repos.json — #{e.message}"
    end

    # Track the registry repos' upstream PRs, so an `@opilot` mention on one gets
    # answered — read-only there, so opilot replies (or offers suggestions)
    # instead of pushing.
    #
    # OFF unless explicitly asked for: the one gh-agent source that reaches outside
    # opilot's own PRs, across whole public repos, so opting in is a decision about
    # a specific repo set. Still requires OPILOT_ALLOWED_GH_USERS — this flag says
    # which PRs to watch, the allowlist whose mentions count (UpstreamGhPull#enabled?).
    def track_upstream_prs?
      %w[1 true yes on].include?(ENV["OPILOT_TRACK_UPSTREAM_PRS"].to_s.strip.downcase)
    end

    # Whether the plan/chat/gh-reply phases get the op_query tool (see MCP.md).
    # ON by default — opt OUT with OPILOT_OP_MCP=0 (or false/no/off). An
    # instance without the (Enterprise-only) MCP server enabled just answers
    # every op_query call with "unavailable", which #report_op_mcp_status and
    # the tool itself both treat as a normal, quiet state, never an error — so
    # defaulting this on costs an idle opgw container on such an instance, not
    # a broken run. This flag is only the tool GRANT; the harness-side
    # extension has its own independent gate on OPILOT_OPGW_URL (empty →
    # registers nothing).
    def op_mcp?
      !%w[0 false no off].include?(ENV["OPILOT_OP_MCP"].to_s.strip.downcase)
    end

    # Work-package type names the `pd` (product development) pipeline maps the
    # OpenSpec model onto: a change becomes one parent WP of the first type, and
    # each top-level tasks.md section becomes a child of the second. Neither is
    # a stock OpenProject type, so both are configurable and are resolved to ids
    # BY NAME at `pd init` (never hardcoded) — a missing type fails fast there
    # rather than surfacing as a confusing 422 two stages later.
    def pd_parent_type
      ENV.fetch("OPILOT_PD_PARENT_TYPE", "FEATURE").strip
    end

    def pd_child_type
      ENV.fetch("OPILOT_PD_CHILD_TYPE", "IMPLEMENTATION").strip
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
      ENV.fetch("OPILOT_PD_IMPLEMENTING_STATUS", "In progress").strip
    end

    def pd_implemented_status
      ENV.fetch("OPILOT_PD_IMPLEMENTED_STATUS", "Developed").strip
    end

    # How many times gh-agent will chase a single PR's CI before giving up and
    # asking for a human (`OPILOT_CI_MAX_ATTEMPTS`, default 5, floored at 1).
    def ci_max_attempts
      [ENV.fetch("OPILOT_CI_MAX_ATTEMPTS", "5").to_i, 1].max
    end

    # Check-run names gh-agent should ignore when reading a PR's CI status
    # (`OPILOT_CI_IGNORE_CHECKS`, comma-separated, case-insensitive). For checks
    # opilot can't fix — e.g. "SaaS tests", which needs secrets a fork PR can't
    # access, so it always fails — chasing them just burns attempts. Defaults to
    # "SaaS tests"; set to empty to ignore none.
    def ci_ignored_checks
      ENV.fetch("OPILOT_CI_IGNORE_CHECKS", "SaaS tests")
         .split(",").map { |s| s.strip.downcase }.reject(&:empty?)
    end

    private

    # nil for a missing OR blank value, so callers can test one thing.
    def presence(value)
      value.to_s.strip.empty? ? nil : value.strip
    end
  end
end
