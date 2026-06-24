# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

`openproject-chomper` is an AI agent that plans fixes for OpenProject work packages, implements them in isolated git clones, and opens draft PRs.

A fix can land in **one or more product repos**. The repos are defined in `repos.json` (a committed registry: a top-level `summary` plus a `repos` array, each with `name`, `upstream` owner/repo, `base` branch, optional `shared_repo_path` local checkout to seed the clone from — else it clones fresh — and a `description`). Claude is shown the registry during planning and declares the target repo(s) on the first line of the plan as `REPOS: <name>[, <name>…]`; `Helpers#record_chosen_repos` parses and stores them in `items/<id>/target_repos.json`. Each repo is a self-contained clone at `.chomper/repos/<name>`, mounted into the claude container at `/repos/<name>`; the runner ships an independent branch + PR to each repo that actually changed (`Chomper::Registry`/`Chomper::Repo` in `lib/chomper/repo.rb`). `repos.json` is the single source of truth for the repo set; each repo's `shared_repo_path` is nil there by default (no machine-specific path in the committed config). The one env knob is `OP_REPO_PATH`: when set, it seeds *only* the openproject clone from that local checkout (`--reference-if-able … --dissociate`, a faster clone), applied in `Registry.override_openproject_seed!` and consumed only by `bin/repos`/provisioning. A wrong/absent path harmlessly falls back to a fresh clone.

Modes:

- **op-agent** — continuous polling loop driven by `@chomper` comments on work packages. When it plans (or chats about) a WP it also pulls in that WP's related work packages (explicit relations plus parent/children), caching each as its own `item.json` and writing a `related.json` index that the plan/chat/fix prompts reference (Claude reads a related WP's full detail only if relevant). The terminal `backlog`/`fix`/`plan` flows share this — related WPs are pulled in at plan/re-plan time
- **gh-agent** — continuous polling loop over GitHub PRs, driven by `@chomper` comments, from **two sources** each tick:
  - **chomper's own PRs** (`GhPull`, those with an `items/<id>/repos/<name>/pr_url.txt`) — "always reply, code if asked": every comment gets a PR reply, and Claude edits the PR's branch only when the comment asks for a concrete change. A code change is committed to the clone and pushed to the bot's fork (with the bot token) to update the draft PR.
  - **upstream PRs that @-mention chomper** (`UpstreamGhPull`, any open PR on a registry repo's `upstream`) — discovered via the GitHub search API (`repo:<upstream> is:pr is:open mentions:<bot-login> updated:>=<cutoff>`, where `<bot-login>` is resolved programmatically from `@github.login`, e.g. `op-chomper`) so a Claude call is spent only on PRs that actually mention the bot. chomper has no write access to these branches, so these intents are `reply_only`: it fetches the PR head read-only, **reviews/answers in text, and never commits or pushes** (`Prompts.pr_review`, read-only tools). Per-PR state lives under `.chomper/upstream_prs/<owner>-<repo>/<number>/`. **Disabled unless `CHOMPER_ALLOWED_GH_USERS` is set** — an open `@chomper` trigger across huge public repos would be a spend/abuse risk.

  Both sources watch the conversation thread and inline review comments, are gated by the GitHub-login allowlist, and merging always stays gated on a maintainer. At startup it asks how far back to scan (same prompt as `op-agent`). The shared PR-content caching/mention-matching lives in `GhPrCache`.
- **backlog** — terminal-driven batch mode: fetches a full WP query, triages by complexity, clusters by complexity tier then Module, and steps through items with terminal approval (`[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`). Decomposes into `triage` (fetch + classify), `show` (preview the cached queue; needs no containers), `process` (work the cached queue without re-fetching), and `plan` (like `process` but stops at each approved plan without shipping)
- **fix** — terminal-driven work packages by id: `./chomper fix <id>...` fetches one or more WPs by id (ignoring filters) and runs the same plan/approve loop for each in turn (one failure doesn't abort the rest)
- **plan** — `./chomper plan <id>...` is the plan-only counterpart of `fix`: same per-id plan/approve loop, but stops once each plan is approved instead of implementing and shipping

## Commands

```bash
# Run the agent (polls every 10s for @chomper mentions)
./chomper op-agent

# Run the GitHub PR agent (polls chomper's PRs for @chomper comments; replies and,
# if asked, writes code and pushes it to the bot's fork to update the draft PR)
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
./chomper reset     # delete .chomper/ (clones included)

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
- **Claude** (Node 20 + Claude Code CLI): wraps `claude -p` via `server.js` HTTP server on port 47291 (internal network only, never published to the host). Accepts prompts with tool grants and session IDs; streams NDJSON back. Runs with `/repos` as its working directory (`working_dir` on the claude service) with every repo's worktree mounted at `/repos/<name>`, so Claude Code still auto-loads `/repos/openproject/CLAUDE.md` (OpenProject symlinks it to `AGENTS.md`) as project memory when it reads files there. It gets a **read-only** Bash grant — it can browse git history (`git log/show/blame/diff`) for context but cannot commit, push, reach a remote, or run any non-git command; tests and linters run later in the real dev env / CI. Two `PreToolUse` hooks (loaded via `--settings /app/claude-settings.json`): `guard-writes.js` blocks file writes outside `/repos`, and `guard-bash.js` allows only read-only git (allowlisted subcommands, no shell metacharacters or output-redirecting options). The runner does all real git (branch, commit, push); the egress proxy blocks exfiltration regardless. Authenticates to Anthropic one of two ways: with an API key (default), via `ANTHROPIC_BASE_URL` → the authgw gateway, carrying only a fixed handshake token so the real key is never in this container; or, with no key set, via stored `claude auth login` OAuth creds (in the claude-auth mount) talking to Anthropic through the proxy.
- **Authgw** (Node 20, `authgw.js`): holds the real `ANTHROPIC_API_KEY`. Validates the fixed gateway token (`CHOMPER_GW_TOKEN`, a non-secret handshake value set in `compose.yml`), injects `x-api-key`, and forwards (streaming) to a hardcoded `api.anthropic.com`. Not an open proxy, so it egresses directly; only inference traffic is redirected here, everything else still goes via the proxy. Keeps the key out of the untrusted claude container.
- **Proxy** (tinyproxy): egress allowlist for the claude container — only hosts matching `tinyproxy-filter` (Anthropic endpoints, Rails docs) are reachable; everything else is denied.

The bash script `./chomper` handles first-run setup (`.env` wizard, cloning each repo) then invokes the runner container.

`compose.yml` mounts are keyed on `SCRIPT_DIR`, which `./chomper` exports as an absolute host path so the repo (and the clones under `.chomper/repos/`) mount at their real paths (the agent computes host paths that must resolve identically inside the container). It defaults to the current project when unset, so bare `docker compose run …` commands (e.g. tests) work from the repo root with no env prefix. Each repo is a **standalone clone** under `.chomper/repos/<name>` (so a single static `.chomper/repos:/repos` mount covers them all — no per-repo source mounts). `./chomper` provisions them in a loop driven by `ruby bin/repos list`: it `git clone`s each repo, using `--reference-if-able <shared_repo_path> --dissociate` when a local checkout is configured so the clone is fast yet stays standalone (the openproject clone reuses your local object store without depending on it afterwards).

### Core Ruby modules (`lib/chomper/`)

| File | Role |
|------|------|
| `context.rb` | Singleton config — env vars, paths, allowed emails, the repo registry (`#repos`) |
| `repo.rb` | `Repo` value object + `Registry` — loads `repos.json`, resolves each repo's clone host/container paths, `by_upstream`/`protected_bases` lookups |
| `pull.rb` | Polls OpenProject; parses `@chomper` comments into `Intent` structs |
| `agent.rb` | Main event loop — dispatches `:chat`, `:plan`, `:approve`, `:fix` intents |
| `gh_pull.rb` | Polls chomper's own open PRs; skips closed/merged PRs and parses `@chomper` PR comments into `GhIntent` structs (gated by the GitHub-login allowlist) |
| `upstream_gh_pull.rb` | Polls every registry repo's `upstream` for open PRs that @-mention chomper (GitHub search pre-filter); yields `reply_only` `GhIntent`s; requires an allowlist |
| `gh_pr_cache.rb` | `GhPrCache` — PR-content caching (`pr.json` keyed by `updated_at`), `@chomper` mention matching, and fresh-comment filtering shared by both pollers |
| `gh_agent.rb` | `gh-agent` event loop — polls both sources; for own PRs replies + writes code + pushes to the fork; for upstream PRs reviews read-only and replies (never pushes) |
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
3. **Implement** — Claude (Read/Write/Edit + read-only Bash) works across each chosen repo's clone on a fix branch (`bug/<id>-<slug>`) in one resumed session, then the runner commits `[<label>] <subject>` (matching the PR title) per repo where the label is `#59942` for numeric ids and bare `STC-162` for semantic ids (`Helpers.wp_label`).
4. **Publish** — For each chosen repo that actually changed, the branch is pushed to the **bot's fork** (`Clients::GitHub#ensure_fork`), commits authored by the bot (`Helpers.adopt_github_author!`), a draft PR opened against that repo's upstream and `base` branch (e.g. `dev` for openproject, `main` for the satellites) with a cross-repo head (`fork_owner:branch`) and `maintainer_can_modify: true`, and a reply posted to the WP with the PR link(s). `Publish#open_pr` takes the target `Repo` and drives upstream/base/worktree from it. With `CHOMPER_PR_MODE=direct` (`Context#direct_pr?`) it skips the fork and pushes straight to the canonical repo, opening a same-repo PR (head `upstream_owner:branch`) with `maintainer_can_modify: false` (GitHub 422s on a same-repo PR otherwise); this requires the token to have push access there. The `protected_branch?` guard (`dev`/`main`/`master`/`release*`) is the backstop in this mode.

`:fix` intent always skips the reviewer (even when `CHOMPER_PLAN_REVIEW` is on) and combines plan + implement in one pass.

### State on disk (`.chomper/` — gitignored)

```
.chomper/
├── op_agent_filters.json    # saved search filters (shared by op-agent and backlog modes)
├── backlog_triage.json      # cached triage results (keyed by filter fingerprint)
├── progress.txt             # pipe-delimited audit log
├── chomp.log                # full prompt/response log
├── items/<wp_id>/
│   ├── item.json            # WP metadata + poll cache + acted_at timestamps
│   ├── related.json         # index of related WPs pulled in at plan time (relations + parent/children): id, relation, subject, status, item_path
│   ├── plan.md              # implementation plan (shared across target repos)
│   ├── target_repos.json    # the repo names Claude chose for this WP (from the plan's REPOS line)
│   ├── backlog_done.txt     # backlog outcome: "dropped" (permanent) or "skipped" (until next triage)
│   ├── session_id           # Claude session for continuity across turns (plan + implement)
│   └── repos/<repo_name>/   # one subdir per repo this WP ships to
│       ├── pr.md            # PR description (per-repo diff)
│       ├── pr_url.txt       # published PR URL
│       ├── pr.json          # gh-agent cache of PR content (comments + reviews), keyed by PR updated_at
│       ├── gh_pr.json       # gh-agent act-state: last_acted_comment_at + chomper's own reply ids
│       └── gh_session_id    # gh-agent's Claude session (separate from session_id)
├── upstream_prs/<owner>-<repo>/<number>/   # gh-agent review state for an upstream PR chomper didn't open
│   ├── pr.json              # cached PR content (comments + reviews)
│   ├── gh_pr.json           # act-state: last_acted_comment_at + chomper's own reply ids
│   └── gh_session_id        # the review session
├── repos/<repo_name>/       # this repo's isolated standalone clone (mounted at /repos/<name>)
└── claude-auth/             # claude CLI config (holds OAuth login creds when no API key is set)
```

### Claude container communication

Runner POSTs to `http://claude:47291` with headers:
- `X-Claude-Tools`: `"Read,Grep,Glob,Bash"` (planning/chat) or `"Read,Grep,Glob,Write,Edit,Bash"` (implementation). Bash is read-only git, gated by `guard-bash.js`. `server.js` rejects any other grant — the allowlist there must stay in sync with `TOOLS_READ`/`TOOLS_IMPL` in `claude.rb`.
- `X-Claude-Model`: model passed to `--model`, pinned by `claude.rb`. One model per WP, chosen once and shared by every session-bound phase (`MODEL_WORK` by default; backlog mode downgrades `trivial`/`simple` items to `MODEL_SIMPLE` via `Claude.model_for`), plus `MODEL_FAST` for the stateless triage pass. Validated by format in `server.js` (not an allowlist — model choice grants no privilege), so model strings don't need syncing there.
- `X-Claude-Session`: session ID (omit on first call; save from response for next turn)

`server.js` spawns `claude -p` with `--output-format stream-json --verbose --model <model>`, streams NDJSON back, and persists the session ID. The spawn sets no `cwd`, so it inherits the container's `/repos` working directory (set via `working_dir` in `compose.yml`), with each repo at `/repos/<name>` — Claude Code loads `/repos/openproject/CLAUDE.md` as project memory when it reads files there.

### Required environment variables (`.env`)

| Variable | Purpose |
|----------|---------|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token (needs read access to WPs and write access to post comments) |
| `OP_REPO_PATH` | Optional. Local openproject checkout to seed the openproject clone from (faster clone); absent → clones fresh. openproject-only — other repos are configured in `repos.json` |
| `GITHUB_TOKEN` | Token for a **dedicated bot account** (not the operator) that is **not a collaborator on the canonical repo**. chomper forks as the bot, pushes branches there, and opens cross-repo PRs against upstream. Prompted by the setup wizard; use a classic `public_repo` token (the account's lack of canonical-repo access is what enforces isolation). Must be a personal/user account. Fine-grained tokens can't open fork→upstream PRs |
| `CHOMPER_ALLOWED_OP_USER_IDS` | Comma-separated OpenProject user ids allowed to trigger agent (the number in a profile URL, `/users/<id>` — not emails, since a non-admin API token can't read other users' emails; the id is taken from each comment's `_links.user.href`). Prompted by the setup wizard; required for the public community instance, empty (= unrestricted) needs explicit confirmation elsewhere |
| `CHOMPER_ALLOWED_GH_USERS` | Comma-separated GitHub logins allowed to trigger `gh-agent`. Defaults to `thykel` (not "everyone" — an open trigger on a public PR would let anyone push code to the branch). Also the on/off switch for **upstream PR review**: when empty, gh-agent still serves chomper's own PRs but does NOT scan upstream PRs at all |
| `ANTHROPIC_API_KEY` | Recommended. When set, held only by the authgw gateway (injected into requests), never in the claude container. If unset, falls back to interactive `claude auth login` (OAuth creds stored in the claude container — less isolated) |
| `CHOMPER_MODEL` | Optional; overrides the work model (default `claude-opus-4-8`) used by moderate/complex items and all agent-mode phases |
| `CHOMPER_SIMPLE_MODEL` | Optional; overrides the model (default `claude-sonnet-4-6`) used for backlog items triaged `trivial` or `simple` |
| `CHOMPER_TRIAGE_MODEL` | Optional; overrides the triage model (default `claude-haiku-4-5`) |
| `CHOMPER_PLAN_REVIEW` | Optional; set `1`/`true` to re-enable the agent-mode self-review pass (off by default — a human approves every plan via `@chomper approve`) |
| `AUTO_PLAN_APPROVAL` | Optional; set `1`/`true` to auto-approve every plan (off by default). Backlog/fix skip the terminal approval prompt; agent mode implements a planned WP immediately instead of waiting for `@chomper approve`. Unattended — use with care |
| `CHOMPER_PR_MODE` | Optional; `fork` (default) or `direct`. `fork` pushes the fix branch to the bot's fork and opens a cross-repo PR, so the token never needs write access to the canonical repo. `direct` pushes the branch straight to the canonical repo and opens a same-repo PR — requires the token to have push access there, and gives up the fork's isolation (the protected-branch guard + human-gated merge become the only safety). The PR is always a draft; merging still needs a maintainer |
| `CHOMPER_MARKDOWN` | Optional; set `0`/`false` to disable terminal Markdown rendering of Claude's streamed output (on by default; auto-skipped when stdout isn't a tty) |
