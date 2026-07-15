# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

`openproject-chomper` is an AI agent that plans fixes for OpenProject work packages, implements them in isolated git clones, and opens draft PRs.

A fix can land in **one or more product repos**. The repos are defined in `repos.json` (a committed registry: a top-level `summary` plus a `repos` array, each with `name`, `upstream` owner/repo, `base` branch, optional `shared_repo_path` local checkout to seed the clone from — else it clones fresh — and a `description`). Claude is shown the registry during planning and declares the target repo(s) on the first line of the plan as `REPOS: <name>[@<base>][, <name>…]`; `Helpers#record_chosen_repos` parses and stores the names in `work_packages/<op_host>/<id>/target_repos.json`. A repo entry may carry an optional `@<base>` (e.g. `openproject@release/17.6`) when the user asks to target a non-default base branch — those overrides are stored in `work_packages/<op_host>/<id>/target_base.json` (`{ "<repo>": "<base>" }`) and the fix branch is both **created from** and the PR **opened against** that branch (`ItemState#base_for`); omitted, each repo uses its `repos.json` default `base`. Each repo is a self-contained clone at `.chomper/repos/<name>`, mounted into the claude container at `/repos/<name>`; the runner ships an independent branch + PR to each repo that actually changed (`Chomper::Registry`/`Chomper::Repo` in `lib/chomper/repo.rb`). `repos.json` is the single source of truth for the repo set; each repo's `shared_repo_path` is nil there by default (no machine-specific path in the committed config). The one env knob is `OP_REPO_PATH`: when set, it seeds *only* the openproject clone from that local checkout (`--reference-if-able … --dissociate`, a faster clone), applied in `Registry.override_openproject_seed!` and consumed only by `bin/repos`/provisioning. A wrong/absent path harmlessly falls back to a fresh clone.

Modes:

- **op-agent** — continuous polling loop driven by `@chomper` comments on work packages. When it plans (or chats about) a WP it also pulls in that WP's related work packages (explicit relations plus parent/children), caching each as its own `item.json` and writing a `related.json` index that the plan/chat/fix prompts reference (Claude reads a related WP's full detail only if relevant). The terminal `ship`/`build`/`plan` flows share this — related WPs are pulled in at plan/re-plan time
- **gh-agent** — continuous polling loop over GitHub PRs, driven by `@chomper` comments, from **two sources** each tick:
  - **chomper's own PRs** (`GhPull`, those with an `work_packages/<op_host>/<id>/repos/<name>/pr_url.txt`) — "always reply, code if asked": every comment gets a PR reply, and Claude edits the PR's branch only when the comment asks for a concrete change. A code change is committed to the clone and pushed to the bot's fork (with the bot token) to update the draft PR. **Optionally also auto-fixes failed CI** (`CHOMPER_CI_FIX`, off by default): when a PR's checks have *completed* with ≥1 failure, chomper fetches the failure detail (check-run annotations + output summaries + the failed Actions jobs' log tails, cached to `ci.json`), fixes the defect in the worktree with `Prompts.fix_ci`, and commits+pushes — same publish path as a comment fix. The trigger is the PR's **head SHA** (not a comment): `gh_pr.json` tracks `ci_acted_sha` (act once per commit) and `ci_attempts` (capped by `CHOMPER_CI_MAX_ATTEMPTS`, default 5; after the cap it posts a one-time "needs a human" note and sets `ci_gave_up`). It acts as soon as the **first** check fails (a fast yamllint failure isn't held up waiting on slow jobs — a pushed fix re-runs everything anyway), waits only while nothing has failed yet but checks are still running, never acts in the same tick as a comment trigger for that PR, ignores unfixable checks (`CHOMPER_CI_IGNORE_CHECKS`, default `SaaS tests`), and needs no user allowlist (the trigger is CI on chomper's own branch, gated solely by `CHOMPER_CI_FIX`). A green verdict is only cached (`ci_quiet_sha`) once the commit has **settled** (`CI_SETTLE_SECONDS`) — checks register over time, so a commit polled seconds after a push can look green before its slow/failing checks register, and caching then would hide them. Check-run reads are fully paginated (Octokit's `auto_paginate` is off by default, which would otherwise truncate a big CI matrix to the first page).
  - **upstream PRs that @-mention chomper** (`UpstreamGhPull`, any open PR on a registry repo's `upstream`) — discovered via the GitHub search API (`repo:<upstream> is:pr is:open mentions:<bot-login> updated:>=<cutoff>`, where `<bot-login>` is resolved programmatically from `@github.login`, e.g. `op-chomper`) so a Claude call is spent only on PRs that actually mention the bot. chomper has no write access to these branches, so these intents are `reply_only`: it fetches the PR head read-only, **reviews/answers in text, and never commits or pushes** (`Prompts.pr_review`, read-only tools). Per-PR state lives under `.chomper/pr_reviews/<owner>-<repo>/<number>/`. **Disabled unless `CHOMPER_ALLOWED_GH_USERS` is set** — an open `@chomper` trigger across huge public repos would be a spend/abuse risk.

  Both sources watch the conversation thread and inline review comments, are gated by the GitHub-login allowlist, and merging always stays gated on a maintainer. At startup it asks how far back to scan (same prompt as `op-agent`). The shared PR-content caching/mention-matching lives in `GhPrCache`.
- **ship** — terminal-driven work packages by id: `./chomper ship <id>...` (alias `fix`) fetches one or more WPs by id (ignoring filters) and runs a plan/approve loop (`[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`) for each in turn (one failure doesn't abort the rest), shipping each approved plan as a draft PR
- **build** — `./chomper build <id>...` is `ship` minus publishing: it implements and commits the approved plan on the fix branch in the local clone(s), then stops — nothing is pushed and no PR is opened. A later `ship <id>` finds the committed branch (`branch_has_commits?`) and goes straight to publish
- **plan** — `./chomper plan <id>...` is the plan-only counterpart of `ship`: same per-id plan/approve loop, but stops once each plan is approved instead of implementing
- **pr** — `./chomper pr <id|pr-url>...` refreshes a WP's shipped PR(s) on demand (`PrRunner` in `lib/chomper/pr_runner.rb`). Targets are WP ids and/or pasted GitHub PR URLs: a URL is first matched against chomper's own state (any `pr_url.txt`, compared on parsed repo+number so URL formatting differences don't matter); an untracked PR is *adopted* via the OpenProject work-package link in the top 15 lines of its description (`Ticket: https://<op-host>/work_packages/<id>` — only links to the configured instance count), creating the normal `<id>/repos/<name>/pr_url.txt` state; a PR whose base repo isn't in `repos.json`, or with no ticket link, is reported and skipped. Before any refresh the WP mirror (`item.json`) is re-fetched the same way `pull` does (`Pull#fetch_single_item`, best-effort — an OpenProject hiccup falls back to the cached copy). For each open PR the WP shipped, it syncs the branch to the PR head, merges in the PR's actual base branch (a conflicted merge is handed to Claude to resolve; unresolved conflicts abort with the merge reset), fixes failing CI (regardless of `CHOMPER_CI_FIX`, act-state, or the attempt cap — the operator is the trigger; a failure older than GitHub's ~1-month log retention — judged by the newest failed check's `completed_at` — has no detail left to fix from, so it skips the Claude CI pass and falls back to the base merge + push, which re-runs CI; when the branch is already in sync there is nothing to push, and the operator is told to re-run the checks from the GitHub UI), and addresses PR comments newer than chomper's last action (no `@chomper` mention or `CHOMPER_ALLOWED_GH_USERS` gate, unlike gh-agent — the point is sweeping up feedback that never pinged chomper). Changes are committed (a clean merge as a merge commit; Claude's edits as a follow-up commit with a generated subject) and pushed to the PR's head repo after a terminal `[y]es push / [d]iscard` confirmation (`AUTO_PLAN_APPROVAL` skips it; discard resets the branch and acknowledges nothing). Claude's summary is posted as a 🤖 PR comment and the per-PR comment cutoff advances so gh-agent doesn't re-handle the same feedback
- **pull** — `./chomper pull [<id>...]` mirrors work packages into the local cache so they can later be discussed via `chat`, without planning or shipping. With ids it fetches exactly those WPs (`Pull#fetch_single_item`, ignoring filters); with no ids it runs the same project-scope filter wizard as `op-agent` (`load_or_prompt_agent_filters`) and bulk-mirrors every match (`Pull#mirror`, which shares `op-agent`'s paginated, scan-window-bounded fetch via `each_filtered_wp` but skips intent parsing). `PullRunner` (`lib/chomper/pull_runner.rb`) is a thin wrapper; needs only an OpenProject token (no GitHub token or allowlist — it just refreshes local `item.json`s)
- **chat** — `./chomper chat [message]` is a free, read-only terminal conversation over chomper's **local mirrors** — not scoped to any one WP and never fetching, planning, or shipping. The whole `.chomper/` cache is already mounted read-only into the claude container at `/state`, so `Prompts.free_chat` just orients Claude at that layout (`work_packages/<op_host>/<id>/` item.json/plan.md/related.json, `<id>/repos/<name>/pr.json` for shipped PR threads, `pr_reviews/…/pr.json` for upstream ones) plus the repo clones at `/repos/<name>`, and Claude Greps/Reads whatever the question needs (read-only Bash for git history). `ChatRunner` (`lib/chomper/chat_runner.rb`) is a small REPL mirroring the ship/build/plan `[c]hat`: a fresh per-run session (`.chomper/chat_session_id`, cleared at start), empty line exits, and an inline `chat <message>` seeds the first turn. Needs no allowlist or GitHub/OpenProject token (it only reads local files)

## Commands

```bash
# Run the agent (polls every 20s for @chomper mentions)
./chomper op-agent

# Run the GitHub PR agent (polls chomper's PRs for @chomper comments; replies and,
# if asked, writes code and pushes it to the bot's fork to update the draft PR)
./chomper gh-agent

# Plan and ship one or more work packages by id (terminal approval; `fix` is an alias)
./chomper ship <id>...

# Like ship, but stop after committing the fix locally — no push, no PR
./chomper build <id>...

# Plan one or more work packages by id, stopping before shipping
./chomper plan <id>...

# Refresh shipped PRs by work-package id or pasted PR URL: merge in the latest
# base branch, fix failing CI, address new review comments, then push (with
# confirmation). A URL is resolved to its WP via the OpenProject ticket link
# at the top of the PR description, and the WP is mirrored first
./chomper pr <id|pr-url>...

# Mirror work packages into the local cache for later chat (no plan or ship);
# ids fetch exactly those, no ids runs the filter wizard for a bulk grab
./chomper pull [<id>...]

# Free read-only chat about the local mirrors (no fetch, plan, or ship)
./chomper chat [message]

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
| `gh_pull.rb` | Polls chomper's own open PRs; skips closed/merged PRs and parses `@chomper` PR comments into `GhIntent` structs (gated by the GitHub-login allowlist); when `CHOMPER_CI_FIX` is on, also yields per-head-SHA `:ci` intents for failed CI |
| `upstream_gh_pull.rb` | Polls every registry repo's `upstream` for open PRs that @-mention chomper (GitHub search pre-filter); yields `reply_only` `GhIntent`s; requires an allowlist |
| `gh_pr_cache.rb` | `GhPrCache` — PR-content caching (`pr.json` keyed by `updated_at`), `@chomper` mention matching, fresh-comment filtering, and CI-failure caching (`ci.json` keyed by head SHA + `ci_status` classifier) shared by the pollers |
| `gh_agent.rb` | `gh-agent` event loop — polls both sources; for own PRs replies + writes code + pushes to the fork (incl. `:ci` auto-fix when enabled); for upstream PRs reviews read-only and replies (never pushes) |
| `fix_runner.rb` | Terminal `ship`/`build`/`plan` — fetch WPs by id, run the plan/approve loop, then ship approved plans as draft PRs (`ship`, alias `fix`), stop after the local commit (`build`), or stop at the approved plan (`plan`) |
| `pr_runner.rb` | Terminal `pr` — refresh a WP's shipped PRs: merge the base branch in, fix failing CI, address unanswered review comments, push after confirmation |
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

Per-instance state is namespaced so pointing chomper at a different
`OPENPROJECT_URL` can't collide (WP #42 on instance A ≠ #42 on instance B):
work packages live under `work_packages/<op_host>/` (`<op_host>` is the host —
plus a non-default port — parsed from `OPENPROJECT_URL` by `Context#op_host`),
and the saved search filters sit beside them. Upstream-PR review state is keyed
by `<owner>-<repo>/<number>` (globally unique on github.com), so it's a flat
`pr_reviews/` with no host segment.

```
.chomper/
├── progress.txt             # pipe-delimited audit log
├── chomp.log                # full prompt/response log
├── chat_session_id          # Claude session for the current `chat` REPL (reset each run)
├── work_packages/<op_host>/                # per-OpenProject-instance WP state
│   ├── op_agent_filters.json   # saved op-agent search filters (project ids are instance-specific)
│   └── <wp_id>/
│       ├── item.json            # WP metadata + poll cache + acted_at timestamps
│       ├── related.json         # index of related WPs pulled in at plan time (relations + parent/children): id, relation, subject, status, item_path
│       ├── plan.md              # implementation plan (shared across target repos)
│       ├── target_repos.json    # the repo names Claude chose for this WP (from the plan's REPOS line)
│       ├── target_base.json     # optional per-repo base-branch overrides ({repo: base}) from REPOS <name>@<base>; absent → default base
│       ├── gist_url.txt         # secret gist of plan.md (one per WP), linked from every repo's PR; created once, then cached
│       ├── session_id           # Claude session for continuity across turns (plan + implement)
│       └── repos/<repo_name>/   # one subdir per repo this WP ships to
│           ├── pr.md            # PR description (per-repo diff)
│           ├── pr_url.txt       # published PR URL
│           ├── pr.json          # gh-agent cache of PR content (comments + reviews), keyed by PR updated_at
│           ├── ci.json          # gh-agent cache of CI failure detail (failed checks + annotations + log tails), keyed by head SHA
│           ├── gh_pr.json       # gh-agent act-state: last_acted_comment_at + reply ids; CI: ci_acted_sha, ci_quiet_sha (green, immutable per SHA), ci_attempts, ci_gave_up
│           └── gh_session_id    # gh-agent's Claude session (separate from session_id)
├── pr_reviews/<owner>-<repo>/<number>/   # gh-agent review state for an upstream PR chomper didn't open
│   ├── pr.json              # cached PR content (comments + reviews)
│   ├── gh_pr.json           # act-state: last_acted_comment_at + chomper's own reply ids
│   └── gh_session_id        # the review session
├── repos/<repo_name>/       # this repo's isolated standalone clone (mounted at /repos/<name>)
└── claude-auth/             # claude CLI config (holds OAuth login creds when no API key is set)
```

### Claude container communication

Runner POSTs to `http://claude:47291` with headers:
- `X-Claude-Tools`: `"Read,Grep,Glob,Bash"` (planning/chat) or `"Read,Grep,Glob,Write,Edit,Bash"` (implementation). Bash is read-only git, gated by `guard-bash.js`. `server.js` rejects any other grant — the allowlist there must stay in sync with `TOOLS_READ`/`TOOLS_IMPL` in `claude.rb`.
- `X-Claude-Model`: model passed to `--model`, pinned by `claude.rb`. One model per WP, shared by every session-bound phase (`MODEL_WORK`), plus `MODEL_FAST` for stateless one-shot passes (e.g. crafting a gh-agent commit subject). Validated by format in `server.js` (not an allowlist — model choice grants no privilege), so model strings don't need syncing there.
- `X-Claude-Session`: session ID (omit on first call; save from response for next turn)

`server.js` spawns `claude -p` with `--output-format stream-json --verbose --model <model>`, streams NDJSON back, and persists the session ID. The spawn sets no `cwd`, so it inherits the container's `/repos` working directory (set via `working_dir` in `compose.yml`), with each repo at `/repos/<name>` — Claude Code loads `/repos/openproject/CLAUDE.md` as project memory when it reads files there.

### Required environment variables (`.env`)

| Variable | Purpose |
|----------|---------|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token (needs read access to WPs and write access to post comments) |
| `OP_REPO_PATH` | Optional. Local openproject checkout to seed the openproject clone from (faster clone); absent → clones fresh. openproject-only — other repos are configured in `repos.json` |
| `GITHUB_TOKEN` | Token for a **dedicated bot account** (not the operator) that is **not a collaborator on the canonical repo**. chomper forks as the bot, pushes branches there, and opens cross-repo PRs against upstream. Prompted by the setup wizard; use a classic token with the `public_repo`, `workflow` and `gist` scopes (the account's lack of canonical-repo access is what enforces isolation — `workflow` is needed because the lagging fork makes a fix branch re-introduce upstream's `.github/workflows/*` files, which GitHub rejects from a classic PAT without that scope; `gist` lets chomper attach each WP's full plan as a secret gist linked from the PR, and the link is simply skipped if the scope is absent). Must be a personal/user account. Fine-grained tokens can't open fork→upstream PRs |
| `CHOMPER_ALLOWED_OP_USER_IDS` | Comma-separated OpenProject user ids allowed to trigger agent (the number in a profile URL, `/users/<id>` — not emails, since a non-admin API token can't read other users' emails; the id is taken from each comment's `_links.user.href`). Prompted by the setup wizard; required for the public community instance, empty (= unrestricted) needs explicit confirmation elsewhere |
| `CHOMPER_ALLOWED_GH_USERS` | Comma-separated GitHub logins allowed to trigger `gh-agent`. Defaults to `thykel` (not "everyone" — an open trigger on a public PR would let anyone push code to the branch). Also the on/off switch for **upstream PR review**: when empty, gh-agent still serves chomper's own PRs but does NOT scan upstream PRs at all |
| `ANTHROPIC_API_KEY` | Recommended. When set, held only by the authgw gateway (injected into requests), never in the claude container. If unset, falls back to interactive `claude auth login` (OAuth creds stored in the claude container — less isolated) |
| `CHOMPER_MODEL` | Optional; overrides the work model (default `claude-opus-4-8`) used for all planning and implementation |
| `CHOMPER_TRIAGE_MODEL` | Optional; overrides the fast model (default `claude-haiku-4-5`) used for stateless one-shot passes (e.g. the gh-agent commit subject) |
| `CHOMPER_PLAN_REVIEW` | Optional; set `1`/`true` to re-enable the agent-mode self-review pass (off by default — a human approves every plan via `@chomper approve`) |
| `AUTO_PLAN_APPROVAL` | Optional; set `1`/`true` to auto-approve every plan (off by default). ship/build/plan skip the terminal approval prompt; agent mode implements a planned WP immediately instead of waiting for `@chomper approve`. Unattended — use with care |
| `CHOMPER_PR_MODE` | Optional; `fork` (default) or `direct`. `fork` pushes the fix branch to the bot's fork and opens a cross-repo PR, so the token never needs write access to the canonical repo. `direct` pushes the branch straight to the canonical repo and opens a same-repo PR — requires the token to have push access there, and gives up the fork's isolation (the protected-branch guard + human-gated merge become the only safety). The PR is always a draft; merging still needs a maintainer |
| `CHOMPER_CI_FIX` | Optional; set `1`/`true` to let `gh-agent` auto-fix failed CI on chomper's own draft PRs (off by default). When a PR's checks complete with a failure, chomper fixes it in the worktree and pushes to update the PR. Autonomous spend + push — opt-in; needs no user allowlist (the trigger is CI on chomper's own branch) |
| `CHOMPER_CI_MAX_ATTEMPTS` | Optional; how many times `gh-agent` will chase one PR's CI before giving up and posting a "needs a human" note (default `5`, floored at 1). Only relevant when `CHOMPER_CI_FIX` is on |
| `CHOMPER_CI_IGNORE_CHECKS` | Optional; comma-separated, case-insensitive check-run names `gh-agent` ignores when reading CI status (default `SaaS tests` — it needs secrets a fork PR can't access, so it always fails and chomper can't fix it). Set empty to ignore none |
| `CHOMPER_MARKDOWN` | Optional; set `0`/`false` to disable terminal Markdown rendering of Claude's streamed output (on by default; auto-skipped when stdout isn't a tty) |
