# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

`openproject-chomper` is an AI agent that plans fixes for OpenProject work packages, implements them in an isolated git worktree, and opens draft PRs. Modes:

- **agent** — continuous polling loop driven by `@chomper` comments on work packages
- **gh-agent** — continuous polling loop over the GitHub PRs chomper has already opened (those with an `items/<id>/pr_url.txt`), driven by `@chomper` comments on the PR. "Always reply, code if asked": every comment gets a PR reply, and Claude edits the PR's branch only when the comment asks for a concrete change. A code change is committed to the worktree and, after a terminal `[y/N]` confirmation, pushed to the bot's fork (with the bot token) to update the draft PR. Watches both the PR conversation thread and inline review comments; gated by a GitHub-login allowlist (`CHOMPER_ALLOWED_GH_USERS`, default `thykel`). At startup it asks how far back to scan (same prompt as `agent`)
- **backlog** — terminal-driven batch mode: fetches a full WP query, triages by complexity, clusters by complexity tier then Module, and steps through items with terminal approval (`[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`). Decomposes into `triage` (fetch + classify), `show` (preview the cached queue; needs no containers), `process` (work the cached queue without re-fetching), and `plan` (like `process` but stops at each approved plan without shipping)
- **fix** — terminal-driven work packages by id: `./chomper fix <id>...` fetches one or more WPs by id (ignoring filters) and runs the same plan/approve loop for each in turn (one failure doesn't abort the rest)
- **plan** — `./chomper plan <id>...` is the plan-only counterpart of `fix`: same per-id plan/approve loop, but stops once each plan is approved instead of implementing and shipping

## Commands

```bash
# Run the agent (polls every 10s for @chomper mentions)
./chomper agent

# Run the GitHub PR agent (polls chomper's PRs for @chomper comments; replies and,
# if asked, writes code, then pushes to the bot's fork after a [y/N] confirmation)
./chomper gh-agent

# Run batch backlog mode (terminal approval per item)
./chomper backlog

# Or phase by phase: triage (fetch + classify) → show (preview) → process (work the cached queue)
./chomper backlog triage
./chomper backlog show
./chomper backlog process

# Walk the cached queue but stop at each approved plan (no shipping)
./chomper backlog plan

# Park a WP until the next triage (local only, no containers)
./chomper backlog skip <id>

# Plan and ship one or more work packages by id (terminal approval)
./chomper fix <id>...

# Plan one or more work packages by id, stopping before shipping
./chomper plan <id>...

# Other CLI modes
./chomper status    # list planned/shipped work packages
./chomper reset     # de-register worktree, delete .chomper/

# Run all tests
docker compose run --no-deps --rm runner bundle exec rake

# Run a single test file
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/chomper/agent_test.rb

# Rebuild runner image (required after editing Gemfile)
docker compose run --no-deps --rm runner bundle lock
docker compose build runner
```

## Architecture

Four Docker containers orchestrated by `compose.yml`:

- **Runner** (Ruby 4.0): the agent. Polls OpenProject, dispatches intents, calls Claude, pushes branches, opens PRs.
- **Claude** (Node 20 + Claude Code CLI): wraps `claude -p` via `server.js` HTTP server on port 47291 (internal network only, never published to the host). Accepts prompts with tool grants and session IDs; streams NDJSON back. Runs with `/repo` as its working directory (`working_dir` on the claude service), so Claude Code auto-loads the product repo's `CLAUDE.md` (OpenProject symlinks it to `AGENTS.md`) as project memory on every session. It gets no Bash grant — the container has no Ruby/Docker to run the product's tooling, so Claude only reads and edits files; tests and linters run later in the real dev env / CI. A `PreToolUse` hook (`guard-writes.js`, loaded via `--settings /app/claude-settings.json`) blocks file writes outside `/repo`. Authenticates to Anthropic one of two ways: with an API key (default), via `ANTHROPIC_BASE_URL` → the authgw gateway, carrying only a fixed handshake token so the real key is never in this container; or, with no key set, via stored `claude auth login` OAuth creds (in the claude-auth mount) talking to Anthropic through the proxy.
- **Authgw** (Node 20, `authgw.js`): holds the real `ANTHROPIC_API_KEY`. Validates the fixed gateway token (`CHOMPER_GW_TOKEN`, a non-secret handshake value set in `compose.yml`), injects `x-api-key`, and forwards (streaming) to a hardcoded `api.anthropic.com`. Not an open proxy, so it egresses directly; only inference traffic is redirected here, everything else still goes via the proxy. Keeps the key out of the untrusted claude container.
- **Proxy** (tinyproxy): egress allowlist for the claude container — only hosts matching `tinyproxy-filter` (Anthropic endpoints, Rails docs) are reachable; everything else is denied.

The bash script `./chomper` handles first-run setup (`.env` wizard, git worktree creation) then invokes the runner container.

`compose.yml` mounts are keyed on `SCRIPT_DIR` and `OP_REPO`, which `./chomper` exports as absolute host paths so the repo and product checkout mount at their real paths (the agent computes host paths that must resolve identically inside the container). Both default to the current project when unset, so bare `docker compose run …` commands (e.g. tests) work from the repo root with no env prefix. `OP_REPO` is deliberately separate from the `OP_REPO_PATH` env var, whose `.env` value may be relative or `false` and is unusable as a mount path.

### Core Ruby modules (`lib/chomper/`)

| File | Role |
|------|------|
| `context.rb` | Singleton config — env vars, paths, allowed emails |
| `pull.rb` | Polls OpenProject; parses `@chomper` comments into `Intent` structs |
| `agent.rb` | Main event loop — dispatches `:chat`, `:plan`, `:approve`, `:fix` intents |
| `gh_pull.rb` | Polls chomper's open PRs; caches each PR's content (comments + reviews) in `pr.json` keyed by the PR's `updated_at`, skips closed/merged PRs, and parses `@chomper` PR comments into `GhIntent` structs (gated by the GitHub-login allowlist) |
| `gh_agent.rb` | `gh-agent` event loop — replies to each PR comment, writes code when asked, commits, and pushes to the bot's fork after a `[y/N]` confirmation |
| `backlog_runner.rb` | Batch backlog mode — triage, cluster by complexity then Module, terminal approval loop; also id-based `fix`/`plan` and plan-only `backlog plan` |
| `claude.rb` | HTTP client to the Claude container; manages per-WP session IDs |
| `prompts.rb` | All Claude prompts in one place |
| `publish.rb` | Pushes branch to the user's fork via git credential helper; opens cross-repo draft PRs against upstream via Octokit |
| `clients/openproject.rb` | OpenProject REST API |
| `clients/github.rb` | GitHub API (Octokit) |
| `clients/http.rb` | Shared HTTP transport with Retriable exponential backoff |

### Per-work-package state machine

1. **Poll** — `Pull#poll_intents` fetches WPs and comments, de-dupes by `last_acted_comment_at`, returns Intents.
2. **Plan** — Claude (Read-only tools) produces `plan.md`. Opt-in reviewer pass (`CHOMPER_PLAN_REVIEW`, off by default) gates on PROCEED/REVISE/REJECT. NEEDS_INFO aborts with a comment.
3. **Implement** — Claude (Read/Write/Edit/Bash) works in an isolated worktree branch (`bug/<id>-<slug>`), commits `[<label>] <subject>` (matching the PR title) where the label is `#59942` for numeric ids and bare `STC-162` for semantic ids (`Helpers.wp_label`).
4. **Publish** — Branch pushed to the **bot's fork** (`Clients::GitHub#ensure_fork`), commits authored by the bot (`Helpers.adopt_github_author!` sets the bot's no-reply identity), a draft PR opened against upstream `dev` with a cross-repo head (`fork_owner:branch`) and `maintainer_can_modify: true`, and a reply posted to the WP with the PR link. chomper runs as a dedicated bot account with no access to the canonical repo.

`:fix` intent always skips the reviewer (even when `CHOMPER_PLAN_REVIEW` is on) and combines plan + implement in one pass.

### State on disk (`.chomper/` — gitignored)

```
.chomper/
├── agent_filters.json       # saved search filters (shared by agent and backlog modes)
├── backlog_triage.json      # cached triage results (keyed by filter fingerprint)
├── progress.txt             # pipe-delimited audit log
├── chomp.log                # full prompt/response log
├── items/<wp_id>/
│   ├── item.json            # WP metadata + poll cache + acted_at timestamps
│   ├── plan.md              # implementation plan
│   ├── pr.md                # PR description
│   ├── pr_url.txt           # published PR URL
│   ├── backlog_done.txt     # backlog outcome: "dropped" (permanent) or "skipped" (until next triage)
│   ├── session_id           # Claude session for continuity across turns
│   ├── pr.json              # gh-agent cache of PR content (comments + reviews), keyed by PR updated_at
│   ├── gh_pr.json           # gh-agent act-state: last_acted_comment_at + chomper's own reply ids
│   └── gh_session_id        # gh-agent's Claude session (separate from session_id)
├── openproject/             # git worktree
└── claude-auth/             # claude CLI config (holds OAuth login creds when no API key is set)
```

### Claude container communication

Runner POSTs to `http://claude:47291` with headers:
- `X-Claude-Tools`: `"Read,Grep,Glob"` (planning/chat) or `"Read,Grep,Glob,Write,Edit"` (implementation — no Bash). `server.js` rejects any other grant — the allowlist there must stay in sync with `TOOLS_READ`/`TOOLS_IMPL` in `claude.rb`.
- `X-Claude-Model`: model passed to `--model`, pinned by `claude.rb`. One model per WP, chosen once and shared by every session-bound phase (`MODEL_WORK` by default; backlog mode downgrades `trivial`/`simple` items to `MODEL_SIMPLE` via `Claude.model_for`), plus `MODEL_FAST` for the stateless triage pass. Validated by format in `server.js` (not an allowlist — model choice grants no privilege), so model strings don't need syncing there.
- `X-Claude-Session`: session ID (omit on first call; save from response for next turn)

`server.js` spawns `claude -p` with `--output-format stream-json --verbose --model <model>`, streams NDJSON back, and persists the session ID. The spawn sets no `cwd`, so it inherits the container's `/repo` working directory (set via `working_dir` in `compose.yml`) — that's what makes Claude Code load the product repo's `CLAUDE.md` as project memory.

### Required environment variables (`.env`)

| Variable | Purpose |
|----------|---------|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token (needs read access to WPs and write access to post comments) |
| `OP_REPO_PATH` | Path to local openproject repo, or `false` to auto-clone |
| `GITHUB_TOKEN` | Token for a **dedicated bot account** (not the operator) that is **not a collaborator on the canonical repo**. chomper forks as the bot, pushes branches there, and opens cross-repo PRs against upstream. Prompted by the setup wizard; use a classic `public_repo` token (the account's lack of canonical-repo access is what enforces isolation). Must be a personal/user account. Fine-grained tokens can't open fork→upstream PRs |
| `CHOMPER_ALLOWED_EMAILS` | Comma-separated emails allowed to trigger agent. Prompted by the setup wizard; required for the public community instance, empty (= unrestricted) needs explicit confirmation elsewhere |
| `CHOMPER_ALLOWED_GH_USERS` | Comma-separated GitHub logins allowed to trigger `gh-agent` on a chomper PR. Defaults to `thykel` (not "everyone" — an open trigger on a public PR would let anyone push code to the branch); set empty to disable the gate |
| `ANTHROPIC_API_KEY` | Recommended. When set, held only by the authgw gateway (injected into requests), never in the claude container. If unset, falls back to interactive `claude auth login` (OAuth creds stored in the claude container — less isolated) |
| `CHOMPER_MODEL` | Optional; overrides the work model (default `claude-opus-4-8`) used by moderate/complex items and all agent-mode phases |
| `CHOMPER_SIMPLE_MODEL` | Optional; overrides the model (default `claude-sonnet-4-6`) used for backlog items triaged `trivial` or `simple` |
| `CHOMPER_TRIAGE_MODEL` | Optional; overrides the triage model (default `claude-haiku-4-5`) |
| `CHOMPER_PLAN_REVIEW` | Optional; set `1`/`true` to re-enable the agent-mode self-review pass (off by default — a human approves every plan via `@chomper approve`) |
| `AUTO_PLAN_APPROVAL` | Optional; set `1`/`true` to auto-approve every plan (off by default). Backlog/fix skip the terminal approval prompt; agent mode implements a planned WP immediately instead of waiting for `@chomper approve`. Unattended — use with care |
| `CHOMPER_MARKDOWN` | Optional; set `0`/`false` to disable terminal Markdown rendering of Claude's streamed output (on by default; auto-skipped when stdout isn't a tty) |
