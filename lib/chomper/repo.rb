require "json"
require "pathname"
require "set"

module Chomper
  # One product repo chomper can plan and ship fixes in. A work package's fix may
  # land in one repo or several; Claude chooses which (see Prompts.plan). Each
  # repo gets its own isolated worktree under .chomper/repos/<name>, mounted into
  # the claude container at /repos/<name>.
  #
  # - name               slug; also the worktree dir name and container path tail
  # - upstream           "owner/repo" to fork (fork mode) and open the PR against
  # - base               PR base / branch-from point (e.g. "dev" or "main")
  # - shared_repo_path   absolute Pathname of a local checkout to make a linked
  #                      worktree from (fast), or nil to clone a standalone copy
  # - description        one-line hint shown to Claude during repo selection
  # - worktree_host      host path of this repo's worktree (.chomper/repos/<name>)
  # - worktree_container its path inside the claude container (/repos/<name>)
  Repo = Struct.new(:name, :upstream, :base, :shared_repo_path, :description,
                    :worktree_host, :worktree_container, keyword_init: true) do
    # True when the worktree is a linked worktree of a local checkout (so the
    # runner must mount that checkout) rather than a standalone clone.
    def linked?
      !shared_repo_path.nil?
    end

    # "owner/repo" → "owner"; the head owner for a same-repo (direct) PR.
    def upstream_owner
      upstream.split("/").first
    end
  end

  # The set of repos chomper works in, loaded from repos.json. When repos.json is
  # absent, falls back to a single openproject entry built from OP_REPO_PATH, so a
  # single-repo setup behaves exactly as before (just at the /repos/openproject path).
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
        # Single-repo fallback: one openproject entry from OP_REPO_PATH.
        summary = ""
        entries = [{ "name" => "openproject", "upstream" => "opf/openproject",
                     "base" => "dev", "shared_repo_path" => op_repo_path.to_s }]
      end

      repos = entries.map { |e| build_repo(e, script_dir: script_dir, state_dir: Pathname(state_dir)) }
      apply_op_repo_path_override!(repos, op_repo_path, script_dir) if config_path.exist?
      new(summary: summary, repos: repos)
    end

    # Bridge for setups that still point at their openproject checkout via the
    # OP_REPO_PATH env var: when repos.json is present, let it override the
    # openproject entry's shared_repo_path (a path → linked worktree; "false" →
    # standalone clone). Other repos are governed solely by repos.json.
    def self.apply_op_repo_path_override!(repos, op_repo_path, script_dir)
      return if op_repo_path.to_s.strip.empty?
      op = repos.find { |r| r.name == "openproject" }
      return unless op
      op.shared_repo_path =
        if op_repo_path.to_s.strip.casecmp?("false")
          nil
        else
          (script_dir / op_repo_path.to_s).expand_path
        end
    end

    def self.build_repo(entry, script_dir:, state_dir:)
      name = entry["name"].to_s
      raise Error, "every repo needs a non-empty \"name\"" if name.empty?
      raise Error, "repo #{name.inspect} needs an \"upstream\" (owner/repo)" \
        if entry["upstream"].to_s.empty?

      raw_path = entry["shared_repo_path"]
      # `false`/absent/"" → standalone clone (nil); otherwise resolve relative to
      # the chomper checkout, mirroring how ./chomper resolves OP_REPO_PATH.
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

    # Branch names no fix branch may ever be pushed to — every repo's base — so
    # the push guard refuses a push to any of them regardless of the registry size.
    def protected_bases
      @repos.map(&:base).to_set
    end
  end
end
