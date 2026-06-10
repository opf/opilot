# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

`openproject-chomper` is an AI agent that plans fixes for OpenProject work packages, implements them in an isolated git worktree, and opens draft PRs. Two modes:

- **agent** — continuous polling loop driven by `@chomper` comments on work packages
- **backlog** — terminal-driven batch mode: fetches a full WP query, triages by complexity, clusters by Module, and steps through items with terminal approval (`[y]es / [s]kip / [d]rop / [c]hat`)

## Commands

```bash
# Run the agent (polls every 10s for @chomper mentions)
./chomper agent

# Run batch backlog mode (terminal approval per item)
./chomper backlog

# Preview the backlog queue (clusters + order) without processing
./chomper backlog show

# Fetch WPs and (re)build the complexity triage only
./chomper backlog triage

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

Three Docker containers orchestrated by `compose.yml`:

- **Runner** (Ruby 4.0): the agent. Polls OpenProject, dispatches intents, calls Claude, pushes branches, opens PRs.
- **Claude** (Node 20 + Claude Code CLI): wraps `claude -p` via `server.js` HTTP server on port 47291 (internal network only, never published to the host). Accepts prompts with tool grants and session IDs; streams NDJSON back. A `PreToolUse` hook (`guard-writes.js`, loaded via `--settings /app/claude-settings.json`) blocks file writes outside `/repo`.
- **Proxy** (tinyproxy): egress allowlist for the claude container — only hosts matching `tinyproxy-filter` (Anthropic endpoints, Rails docs) are reachable; everything else is denied.

The bash script `./chomper` handles first-run setup (`.env` wizard, git worktree creation) then invokes the runner container.

`compose.yml` mounts are keyed on `SCRIPT_DIR` and `OP_REPO`, which `./chomper` exports as absolute host paths so the repo and product checkout mount at their real paths (the agent computes host paths that must resolve identically inside the container). Both default to the current project when unset, so bare `docker compose run …` commands (e.g. tests) work from the repo root with no env prefix. `OP_REPO` is deliberately separate from the `OP_REPO_PATH` env var, whose `.env` value may be relative or `false` and is unusable as a mount path.

### Core Ruby modules (`lib/chomper/`)

| File | Role |
|------|------|
| `context.rb` | Singleton config — env vars, paths, allowed emails |
| `pull.rb` | Polls OpenProject; parses `@chomper` comments into `Intent` structs |
| `agent.rb` | Main event loop — dispatches `:chat`, `:plan`, `:approve`, `:fix` intents |
| `backlog_runner.rb` | Batch backlog mode — triage, cluster by Module, terminal approval loop |
| `claude.rb` | HTTP client to the Claude container; manages per-WP session IDs |
| `prompts.rb` | All Claude prompts in one place |
| `publish.rb` | Pushes branch via git credential helper; opens draft PRs via Octokit |
| `clients/openproject.rb` | OpenProject REST API |
| `clients/github.rb` | GitHub API (Octokit) |
| `clients/http.rb` | Shared HTTP transport with Retriable exponential backoff |

### Per-work-package state machine

1. **Poll** — `Pull#poll_intents` fetches WPs and comments, de-dupes by `last_acted_comment_at`, returns Intents.
2. **Plan** — Claude (Read-only tools) produces `plan.md`. Optional reviewer pass gates on PROCEED/REVISE/REJECT. NEEDS_INFO aborts with a comment.
3. **Implement** — Claude (Read/Write/Edit/Bash) works in an isolated worktree branch (`bug/<id>-<slug>`), commits `fix: <subject> (WP #<id>)`.
4. **Publish** — Branch pushed, draft PR opened against `dev`, reply posted to WP with PR link.

`:fix` intent skips the reviewer and combines plan + implement in one pass.

### State on disk (`.chomper/` — gitignored)

```
.chomper/
├── agent_filters.json       # saved search filters (agent mode)
├── backlog_filters.json     # saved search filters (backlog mode)
├── backlog_triage.json      # cached complexity map, Module field key + fetched item ids (keyed by filter fingerprint)
├── progress.txt             # pipe-delimited audit log
├── chomp.log                # full prompt/response log
├── items/<wp_id>/
│   ├── item.json            # WP metadata + poll cache + acted_at timestamps
│   ├── plan.md              # implementation plan
│   ├── pr.md                # PR description
│   ├── pr_url.txt           # published PR URL
│   ├── backlog_done.txt     # backlog outcome: "dropped" (permanent skip)
│   └── session_id           # Claude session for continuity across turns
├── openproject/             # git worktree
└── claude-auth/             # persisted Claude CLI auth
```

### Claude container communication

Runner POSTs to `http://claude:47291` with headers:
- `X-Claude-Tools`: `"Read"` (planning/chat) or `"Read,Write,Edit,Bash(bin/compose),Bash(bin/compose *)"` (implementation). `server.js` rejects any other grant — the allowlist there must stay in sync with `TOOLS_READ`/`TOOLS_IMPL` in `claude.rb`.
- `X-Claude-Session`: session ID (omit on first call; save from response for next turn)

`server.js` spawns `claude -p` with `--output-format stream-json --verbose`, streams NDJSON back, and persists the session ID.

### Required environment variables (`.env`)

| Variable | Purpose |
|----------|---------|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token (needs read access to WPs and write access to post comments) |
| `OP_REPO_PATH` | Path to local openproject repo, or `false` to auto-clone |
| `GITHUB_TOKEN` | For pushing branches and opening PRs |
| `CHOMPER_ALLOWED_EMAILS` | Comma-separated emails allowed to trigger agent. Prompted by the setup wizard; required for the public community instance, empty (= unrestricted) needs explicit confirmation elsewhere |
| `ANTHROPIC_API_KEY` | Optional; falls back to `claude auth login` |
