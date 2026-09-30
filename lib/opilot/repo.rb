require "json"
require "pathname"

module OPilot
  # One product repo opilot can plan and ship fixes in. A work package's fix may
  # land in one repo or several; the LLM chooses which (see Prompts::Planner.plan). Each
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
end
