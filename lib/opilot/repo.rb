require "json"
require "pathname"

module OPilot
  # One product repo opilot can plan and ship fixes in. A work package's fix may
  # land in one repo or several; the LLM chooses which (see Prompts.plan). Each
  # repo is a self-contained clone under .opilot/repos/<name>, mounted into the
  # harness container at /repos/<name>.
  #
  # - name               slug; also the checkout dir name and container path tail
  # - upstream           "owner/repo" to clone, fork (fork mode), and open the PR against
  # - base               PR base / branch-from point (e.g. "dev" or "main")
  # - shared_repo_path   absolute Pathname of a local checkout to seed the clone
  #                      from (`git clone --reference-if-able … --dissociate`, so
  #                      the clone is fast yet stays standalone), or nil to clone
  #                      fresh from upstream
  # - description        one-line hint shown to the LLM during repo selection
  # - worktree_host      host path of this repo's checkout (.opilot/repos/<name>)
  # - worktree_container its path inside the harness container (/repos/<name>)
  Repo = Struct.new(:name, :upstream, :base, :shared_repo_path, :description,
                    :worktree_host, :worktree_container, keyword_init: true)

  # The set of repos opilot works in, loaded from repos.json (the single source
  # of truth). `op_repo_path:` (from the OP_REPO_PATH env var) optionally points
  # the openproject clone at a local checkout to seed from — repos.json keeps
  # shared_repo_path nil by default, so the committed config carries no
  # machine-specific path. When no repos.json is present, it also synthesizes the
  # single openproject fallback entry (used by tests).
  class Registry
    class Error < StandardError; end

    DEFAULT_BASE = "main".freeze

    attr_reader :summary, :repos

    def self.build(script_dir:, state_dir:, op_repo_path: nil, config_path: nil)
      script_dir = Pathname(script_dir)
      config_path ||= script_dir / "repos.json"

      if config_path.exist?
        doc = JSON.parse(config_path.read)
        raise Error, "repos.json must be a JSON object with a \"repos\" array" \
          unless doc.is_a?(Hash) && doc["repos"].is_a?(Array)
        summary = doc["summary"].to_s
        entries = doc["repos"]
      else
        # No repos.json: synthesize a single openproject entry (op_repo_path seeds
        # its clone). Production always ships a repos.json, so this is the test path.
        summary = ""
        entries = [{ "name" => "openproject", "upstream" => "opf/openproject",
                     "base" => "dev", "shared_repo_path" => op_repo_path.to_s }]
      end

      repos = entries.map { |e| build_repo(e, script_dir: script_dir, state_dir: Pathname(state_dir)) }
      # OP_REPO_PATH seeds the openproject clone from a local checkout. (For the
      # no-repos.json fallback the entry already carries op_repo_path, so only
      # override when repos.json supplied the entries.)
      override_openproject_seed!(repos, op_repo_path, script_dir) if config_path.exist?
      new(summary: summary, repos: repos)
    end

    # Point the openproject clone at a local seed checkout, from OP_REPO_PATH.
    # openproject-only — other repos always clone fresh. Empty/"false" = no seed.
    def self.override_openproject_seed!(repos, op_repo_path, script_dir)
      val = op_repo_path.to_s.strip
      return if val.empty? || val.casecmp?("false")
      op = repos.find { |r| r.name == "openproject" }
      op.shared_repo_path = (Pathname(script_dir) / val).expand_path if op
    end

    def self.build_repo(entry, script_dir:, state_dir:)
      name = entry["name"].to_s
      raise Error, "every repo needs a non-empty \"name\"" if name.empty?
      raise Error, "repo #{name.inspect} needs an \"upstream\" (owner/repo)" \
        if entry["upstream"].to_s.empty?

      raw_path = entry["shared_repo_path"]
      # `false`/absent/"" → clone fresh from upstream (nil); otherwise resolve the
      # seed checkout relative to the opilot checkout.
      shared = if raw_path.nil? || raw_path == false || raw_path.to_s.strip.empty?
                 nil
               else
                 (script_dir / raw_path.to_s).expand_path
               end

      Repo.new(
        name:               name,
        upstream:           entry["upstream"].to_s,
        base:               (entry["base"].to_s.empty? ? DEFAULT_BASE : entry["base"].to_s),
        shared_repo_path:   shared,
        description:        entry["description"].to_s,
        worktree_host:      state_dir / "repos" / name,
        worktree_container: "/repos/#{name}"
      )
    end

    def initialize(summary:, repos:)
      raise Error, "the repo registry is empty" if repos.empty?
      names = repos.map(&:name)
      dupes = names.select { |n| names.count(n) > 1 }.uniq
      raise Error, "duplicate repo name(s) in repos.json: #{dupes.join(", ")}" if dupes.any?
      @summary = summary
      @repos   = repos
      @by_name = repos.to_h { |r| [r.name, r] }
    end

    # All repos, in registry order (first = default).
    def all
      @repos
    end

    def [](name)
      @by_name[name.to_s]
    end

    # The repo used when none is chosen — the first entry (openproject).
    def default
      @repos.first
    end

    # The repo a PR's base "owner/repo" belongs to (used by gh-agent to map a PR
    # back to its worktree); falls back to the default repo.
    def by_upstream(owner_repo)
      @repos.find { |r| r.upstream.casecmp?(owner_repo.to_s) } || default
    end
  end
end
