## [Internal Experimental PoC! Please do not share with anyone.]

# openproject-chomper

An OpenProject AI development orchestrator that helps you implement work packages, end to end.

**Agent mode**: Talks to you via the WP Activity tab -- just tag `@chomper` to chat, plan together, and generate a draft PR.

**Script mode**: Plans & implements WPs entirely via your terminal. Point it to a specific package by ID, or even to an entire project backlog.

<img width="817" height="597" alt="Screenshot 2026-06-16 at 15 15 26" src="https://github.com/user-attachments/assets/706ddeb1-df10-485d-af48-8821135eafda" />

---

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Bird's-eye view](#birds-eye-view)
- [Commands](#commands)
- [Reviewing & pushing](#reviewing--pushing)
- [Repo layout](#repo-layout)
- [Environment variables](#environment-variables)
- [Development](#development)
- [Reference](#reference)
- [TODO](#todo)

---

## Requirements

- **Docker**
- A GitHub token with repo write access (for opening PRs)
- An OpenProject API token (read-only for script mode, comment-writable for agent mode)

---

## Quick start

```bash
git clone https://github.com/opf/openproject-chomper
cd openproject-chomper
cp .env.example .env
# edit .env OR just leave it to the first startup wizard

# Run the agent: it polls OpenProject WPs via the configured query and acts on @chomper mentions
./chomper op-agent
# OR let it process your whole backlog
./chomper backlog <triage|show|process>
# OR run a one-time E2E fix of one or more specific WPs
./chomper fix <id>...
```

## Bird's-eye view

```
              ┌─────────────────┐
              │    ./chomper    │
              │ (shell wrapper) │
              └─────────────────┘
                       │
                       │ docker compose exec
                       │
┌─ Docker ─────────────┼──────────────────────────────────────────────┐
│                      ▼                                              │
│    ┌─────────── runner container ───────────┐                       │
│    │                                        │                       │
│    │ Ruby 4.0 script                        │                       │     ┌──────────┐
│    │  * Pulls WP content from OP API        ├───────────────────────┤────▶│  OP API  │
│    │  * Manages metadata in .chomper/       │                       │     └──────────┘
│    │      * WP metadata mirror              │                       │
│    │      * Plan files                      │                       │
│    │      * Draft PR data                   │                       │     ┌────────────┐
│    │  * Pushes branches and opens PRs       ├───────────────────────┤────▶│ GitHub API │
│    │  * Delegates conversations to Claude   │                       │     └────────────┘
│    └────────────────────────────────────────┘                       │
│                      ▲                                              │
│                      │ json                                         │
│                      ▼                                              │
│   ┌──────────── claude container ────────────┐   ┌─── proxy ───┐    │
│   │ Node.js server (:47291)                  │   │ tinyproxy   │    │   ┌────────────────────────┐
│   │   POST / → `claude -p`                   │──▶│ (:8888)     ├────┼──▶│ Anthropic telemetry,   │
│   │                                          │   │ egress      │    │   │ Rails docs (allowlist) │
│   │ volumes:                                 │   │ allowlist   │    │   └────────────────────────┘
│   │   .chomper/            → /state  (ro)    │   └─────────────┘    │
│   │   .chomper/openproject → /repo   (rw)    │   ┌── authgw ───┐    │   ┌────────────────────────┐
│   │                                          │   │ injects     │    │   │ api.anthropic.com      │
│   │ no real API key — inference via authgw,  │──▶│ x-api-key   ├────┼──▶│ (inference)            │
│   │ everything else via proxy; internal-only │   │ (real key)  │    │   └────────────────────────┘
│   └──────────────────────────────────────────┘   └─────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### Security model

The claude container processes untrusted text (work package descriptions and
comments), so it is boxed in from several directions:

* **No host or LAN exposure** — port 47291 is not published; the container sits
  on an `internal: true` Docker network reachable only by the runner.
* **Server-side tool allowlist** — `server.js` refuses any `X-Claude-Tools`
  grant that isn't one of the two known tool sets, and validates session IDs.
* **Egress allowlist** — all outbound traffic goes through a tinyproxy sidecar
  that only permits Anthropic endpoints (plus Rails docs); a prompt injection
  has no channel to exfiltrate data.
* **API key isolation** — when an API key is configured, the real
  `ANTHROPIC_API_KEY` lives only in the separate `authgw` gateway, which injects
  it into inference requests; the claude container carries just a fixed
  (non-secret) handshake token, so a prompt injection can cause API calls but
  cannot read or exfiltrate the key. (The optional `claude auth login` fallback
  trades this away — OAuth creds then live in the claude container, though the
  egress allowlist still limits where they could go.)
* **Write confinement** — a `PreToolUse` hook (`guard-writes.js`) blocks any
  file mutation outside `/repo`, and the `.chomper` state dir is additionally
  mounted **read-only** (`/state`), so plans, cached state, and session files
  can't be tampered with even if the hook were bypassed.
* **Container hardening** — read-only rootfs, `cap_drop: ALL`,
  `no-new-privileges`, and no OpenProject/GitHub tokens or Anthropic API key in
  the environment.
* **Human gate** — everything ships as a *draft* PR; review it as untrusted
  code, since WP content can attempt prompt injection.

---

## Commands

| Invocation | Behaviour |
|---|---|
| `./chomper op-agent` | Poll OpenProject every 10s and act on `@chomper` mentions |
| `./chomper backlog` | Run `triage` + `show` + `process` |
| `./chomper backlog triage` | Fetch WPs and (re)build the complexity triage cache, then stop |
| `./chomper backlog show` | Preview the backlog queue |
| `./chomper backlog process` | Work the cached queue without re-fetching (fails if `triage` hasn't run) |
| `./chomper backlog skip <id>` | Park a WP until the next triage, without walking the queue — local only, starts no containers |
| `./chomper fix <id>...` | Plan and ship one or more work packages by id, with the same terminal approval loop (each id runs in turn; one failure doesn't abort the rest) |
| `./chomper status` | List the work packages chomper has planned or shipped |
| `./chomper reset` | De-register any git worktrees and delete `.chomper/` (fresh start) |
| `./chomper --help` | Show usage |

### `./chomper backlog` flow

On first run, prompts you to save a filter (project / types / statuses / version — shared with agent mode). Then:

1. Resolves the **Module** custom field from the per-type WP schemas (`/work_packages/schemas/<project>-<type>`) and fetches all matching work packages.
2. Runs a Claude triage pass to estimate complexity for each item. The result is cached in `backlog_triage.json` and reused while the filters stay the same.
3. Orders the queue by complexity (trivial first), grouping by Module within each tier (a multi-module WP counts under its first module) — the easiest items come up first regardless of module.
4. Steps through items one by one, streaming an implementation plan for each.
5. Prompts: `[y]es implement / [s]kip / [d]rop / [c]hat / [r]e-plan`
   - **y** — implement, commit, and open a draft PR (same as `@chomper fix`)
   - **s** — skip; parked until the next `backlog triage` rebuilds the queue (the plan is kept for later)
   - **d** — drop; item is permanently excluded from future backlog runs
   - **c** — open a chat session to ask questions before deciding; chat alone never changes the saved plan
   - **r** — rewrite `plan.md` from feedback you type, or — left empty — from the changes discussed in the preceding chat
6. Items already shipped (`pr_url.txt` present), dropped, or skipped (`backlog_done.txt`) are passed over automatically. A fresh triage clears skips; drops are permanent.

The phases also run separately: `backlog triage` fetches and classifies, `backlog show` previews the cached queue (instant — reads only local caches and starts no containers), and `backlog process` works the cached queue without re-fetching. `backlog skip <id>` parks an item from outside the queue walk. `fix <id>...` runs the same plan/approve loop for one or more WPs by id, ignoring filters (and overriding a previous drop or skip); with several ids each runs in turn and one failure doesn't abort the rest.

### `@chomper` comment commands

While the agent runs, drive it by mentioning `@chomper` in a comment on any watched work package:

| Comment | Behaviour |
|---|---|
| `@chomper fix [feedback]` | Plan and ship in one step — the right choice for most tasks |
| `@chomper plan [feedback]` | For complex tasks: draft a plan for human review before touching any code (optional feedback revises an existing plan) |
| `@chomper approve` | Implement and ship a plan that was drafted with `@chomper plan` |
| `@chomper <anything else>` | Chat — replies using the current plan as context, no state change |

Triggers are gated by the `CHOMPER_ALLOWED_EMAILS` allowlist (when set). A work
package's status is just the files in `.chomper/items/<id>/`: `plan.md` present
means it has a plan, `pr_url.txt` present means it shipped.

---

## Reviewing & pushing

`@chomper approve` (and `@chomper fix`) push the branch and open a **draft** PR in
one step, posting the PR link back to the work package. This is idempotent — if a
PR already exists for the branch, the existing URL is reported instead of opening
a new one, and re-sending `approve` after a shipped fix just re-reports it.

`./chomper status` lists each watched work package with its OpenProject link and
PR link so you can see what's been planned and shipped at a glance.

---

## Repo layout

**What you clone:**

```
openproject-chomper/
├── chomper                  ← bash entry point (sets up Docker, runs runner)
├── bin/chomper              ← Ruby CLI (runs inside the runner container)
├── lib/chomper/
│   ├── cli.rb              ← command dispatch (agent / backlog / fix / status / reset)
│   ├── context.rb          ← shared config and paths
│   ├── clients.rb          ← requires clients/
│   ├── clients/
│   │   ├── http.rb         ← transport layer (retry, auth, JSON parsing)
│   │   ├── openproject.rb  ← OpenProject REST API client (all endpoint calls)
│   │   └── github.rb       ← GitHub client (branch push, PR lookup and creation)
│   ├── helpers.rb          ← shared utilities (branch_slug, strip_ansi, …)
│   ├── pull.rb             ← poll OpenProject, turn @chomper comments into intents
│   ├── agent.rb            ← the loop: handle chat / plan / approve / fix
│   ├── backlog_runner.rb   ← batch backlog mode (triage, cluster by module, terminal approval) + single-WP fix
│   ├── prompts.rb          ← all Claude prompts
│   ├── publish.rb          ← push branch, open draft PR
│   ├── claude.rb           ← HTTP client for the Claude container
│   └── ui.rb               ← status display, usage, reset
├── test/
│   ├── test_helper.rb
│   └── chomper/
│       ├── agent_test.rb
│       ├── backlog_runner_test.rb
│       ├── context_test.rb
│       ├── helpers_test.rb
│       ├── http_test.rb
│       └── pull_test.rb
├── server.js                ← Node.js HTTP wrapper around `claude -p`
├── Dockerfile.runner        ← Ruby 4.0 image
├── Dockerfile.claude        ← Node.js + Claude Code image
├── compose.yml
├── Gemfile / Gemfile.lock
├── Rakefile
└── README.md
```

**Runtime state (gitignored, created on first run):**

```
.chomper/
├── op_agent_filters.json   ← saved search filters (shared by op-agent and backlog modes)
├── backlog_triage.json  ← cached triage results (keyed by filter fingerprint)
├── progress.txt         ← progress log
├── chomp.log            ← full prompt + response log
├── claude-auth/         ← claude CLI config (holds OAuth login creds when no API key is set)
├── openproject/         ← git worktree or fresh clone of openproject
└── items/
    └── <id>/
        ├── item.json        ← full WP metadata + last_acted_comment_at (poll cache)
        ├── plan.md          ← implementation plan (present = "has a plan")
        ├── review.txt       ← Reviewer's critique (deleted after plan review)
        ├── pr.md            ← generated PR description
        ├── pr_url.txt       ← PR URL (present = "shipped")
        ├── backlog_done.txt ← backlog outcome: "dropped" (permanent skip)
        └── session_id       ← Claude session ID for per-WP chat continuity
```

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OPENPROJECT_URL` | — | URL of your OpenProject instance |
| `OPENPROJECT_TOKEN` | — | OpenProject API token (My Account → Access Tokens); needs WP read access plus comment write — chomper posts replies and 👀 reactions |
| `ANTHROPIC_API_KEY` | — | Recommended. When set, held only by the `authgw` gateway (injected into Anthropic requests), never passed to the claude container. If unset, chomper falls back to interactive `claude auth login` — OAuth creds then live in the claude container (less isolated). The setup wizard prompts for it (blank = use login). |
| `GITHUB_TOKEN` | — | Used to push branches and open PRs via the GitHub API |
| `CHOMPER_ALLOWED_EMAILS` | — | Comma-separated emails allowed to trigger the agent via `@chomper` comments. The setup wizard prompts for this; it is **required when targeting the public community instance** (otherwise anyone on the internet could trigger the agent), and leaving it empty elsewhere needs explicit confirmation. |

---

## Development

The test suite runs inside the runner container so the Ruby version and gem environment match production exactly.

**Run all tests:**

```bash
docker compose run --no-deps --rm runner bundle exec rake
```

**Run a single file:**

```bash
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/chomper/agent_test.rb
```

**After changing `Gemfile`**, regenerate the lockfile and rebuild the image:

```bash
docker compose run --no-deps --rm runner bundle lock
docker compose build runner
```

The suite uses Minitest (ships with Ruby) and WebMock for HTTP stubs. No network calls are made during the test run.

---

## Reference
**`items/<id>/item.json` schema** (full WP metadata, written at poll time)

```json
{
  "id":          "42",
  "subject":     "Null check in UserService",
  "type":        "Bug",
  "url":         "https://community.openproject.org/work_packages/42",
  "status":      "New",
  "priority":    "Normal",
  "assignee":    "unassigned",
  "responsible": "unassigned",
  "author":      "Jane Smith",
  "version":     "14.0",
  "category":    "auth",
  "module":      "Comments and activity",
  "created_at":  "2024-01-15T10:00:00Z",
  "updated_at":  "2024-01-20T14:30:00Z",
  "description": "Raw description text...",
  "comments": [
    {"user": "John Doe", "created_at": "2024-01-16T09:00:00Z", "text": "I can reproduce this..."}
  ]
}
```

---

## TODO

### Security

### AI Architecture
* Migrate from `claude -p` to a Claude SDK 
* Replace Claude Code with a generic AI "file edit engine" layer
  * The LLM container should run something like `LiteLLM` or `OpenCode`, so that we can configure any model we like, commercial or open.
  * The infra is ready for this, we can just replace the chomper-claude container with some other thing that listens on HTTP :47291
* Replace Claude!
  * We can likely save a lot on costs by switching to Codex. 
  * Or, lean away from US by switching to Mistral. 
  * Or, **ideally**, plug in an open model.
* Centralize our skill and agent definitions into another OP repo, so that Chomper may leverage them
  * Good candidate: https://github.com/opf/openproject-agent-skills
* Use separate agents for development and review to clearly split domain ownership
* Try to compact token usage
  * Inspiration: https://andrewpatterson.dev/posts/token-savings-rtk-headroom/
  
### Feature ideas
* **Plug in the other repos: `commonmark-ckeditor-build`, `op-blocknote-extensions` etc.**
* Make the agent mode work off webhooks instead of constant polling
* Update the WP while work is being done: transition to "in development", add release, etc.
* Re-add `<mention>` support for agent interactions
* Correctly set the target branch for release-specific fixes
  * rough idea: If the WP Version field is set to {ver} AND `origin/release/{ver}[\.0-9]*` exists AND we're past the release freeze day, base the PR on the release branch
  * Or, just set it manually for now. Or, explicitly prompt for it (when setting up new search filter query)
* Consider running actual tests -- tricky, as they'd need to be run via the `docker compose` stack on the host system
  * There _are_ ways of giving the runner container access to Docker via a shared socket. However, this breaks the sandbox model, as it escalates the runner's permissions to run/access any containers on the host system.
* Extend search filters to be able to target a backlog bucket or a set of modules
* Idea: Use sub-WPs for any Chomper interactions in agent mode
