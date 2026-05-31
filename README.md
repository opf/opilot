## [Internal Experimental PoC! Please do not share with anyone.]

# openproject-chomper

An agent that watches OpenProject work packages and acts on `@chomper` mentions: it plans a fix, implements it, and opens a draft PR — all inside a Docker container. You drive it from the comments; you review and merge when you're happy.

```
./chomper agent → comment "@chomper fix" on a bug → wait for the draft PR
```

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

- **Docker** (runs both the Ruby runner and the Claude Code container)
- A GitHub token with repo write access (for opening PRs)
- An OpenProject API token (preferably scoped only to reading your target WPs)
- Optionally, a local `openproject` repo — chomper can clone one automatically if you don't have it

---

## Quick start

```bash
git clone https://github.com/opf/openproject-chomper
cd openproject-chomper
cp .env.example .env
# edit .env — set OPENPROJECT_URL, OPENPROJECT_TOKEN, GITHUB_TOKEN

# Run the agent: it polls OpenProject and acts on @chomper mentions
./chomper agent

# Then, on any watched work package, comment:
#   @chomper plan        → draft an implementation plan
#   @chomper approve     → implement the plan and open a draft PR
#   @chomper fix         → plan and ship in one step
#   @chomper <question>  → chat (replies with the plan as context)

# See what's been planned / shipped
./chomper status
```

## Bird's-eye view

```
               ┌─────────────────┐
               │   ./chomper     │
               │ (shell wrapper) │
               └─────────────────┘
                        │
                        │                    
                        │ docker compose exec
                        │
┌─ Docker ──────────────┼──────────────────────────┐
│                       ▼                          │
│    ┌─────────── runner container ────────────┐   │
│    │                                         │   │
│    │ Ruby 4.0 script                         │   │
│    │  * Pulls WP content from OP API         │   │
│    │  * Manages metadata in .chomper/        │   │
│    │      * WP metadata mirror               │   │
│    │      * Plan files                       │   │
│    │      * Draft PR data                    │   │ 
│    │  * Pushes branches and opens PRs        │   │
│    │  * Delegates conversation to Claude     │   │
│    │      * HTTP POST http://claude:3000     │   │
│    │                                         │   │
│    │                                         │   │
│    └─────────────────────────────────────────┘   │
│                        ▲                         │
│                        │                         │
│                        │ json                    │
│                        │                         │
│                        ▼                         │       
│   ┌──────────── claude container ─────────────┐  │
│   │                                           │  │
│   │  Node.js server (:3000)                   │  │
│   │    POST / → `claude -p`                   │  │
│   │                                           │  │
│   │  volumes:                                 │  │
│   │    .chomper/            → /state  (rw)    │  │
│   │    .chomper/openproject → /repo   (rw)    │  │
│   │                                           │  │
│   └───────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘

```

---

## Commands

chomper is agent-first: a single long-lived loop driven by `@chomper` comments.

| Invocation | Behaviour |
|---|---|
| `./chomper agent` | Poll OpenProject every 10s and act on `@chomper` mentions |
| `./chomper status` | List the work packages chomper has planned or shipped |
| `./chomper reset` | De-register the worktree and delete `.chomper/` (fresh start) |
| `./chomper --help` | Show usage |

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
│   ├── cli.rb              ← command dispatch (agent / status / reset)
│   ├── context.rb          ← shared config and paths
│   ├── clients.rb          ← requires clients/
│   ├── clients/
│   │   ├── http.rb         ← transport layer (retry, auth, JSON parsing)
│   │   ├── openproject.rb  ← OpenProject REST API client (all endpoint calls)
│   │   └── github.rb       ← GitHub client (branch push, PR lookup and creation)
│   ├── helpers.rb          ← shared utilities (branch_slug, strip_ansi, …)
│   ├── pull.rb             ← poll OpenProject, turn @chomper comments into intents
│   ├── agent.rb            ← the loop: handle chat / plan / approve / fix
│   ├── prompts.rb          ← all Claude prompts
│   ├── publish.rb          ← push branch, open draft PR
│   ├── claude.rb           ← HTTP client for the Claude container
│   └── ui.rb               ← status display, usage, reset
├── test/
│   ├── test_helper.rb
│   └── chomper/
│       ├── agent_test.rb
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
├── agent_filters.json ← saved search filters (which WPs to watch)
├── progress.txt       ← progress log
├── chomp.log          ← full prompt + response log
├── claude-auth/       ← persisted Claude container auth
├── openproject/       ← git worktree or fresh clone of openproject
└── items/
    └── <id>/
        ├── item.json    ← full WP metadata + last_acted_comment_at (poll cache)
        ├── plan.md      ← implementation plan (present = "has a plan")
        ├── review.txt   ← Reviewer's critique (deleted after plan review)
        ├── pr.md        ← generated PR description
        └── pr_url.txt   ← PR URL (present = "shipped")
```

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OPENPROJECT_URL` | — | URL of your OpenProject instance |
| `OPENPROJECT_TOKEN` | — | Read-only OpenProject API token (My Account → Access Tokens → View work packages) |
| `ANTHROPIC_API_KEY` | — | Passed into the Claude container; falls back to stored auth if unset |
| `GITHUB_TOKEN` | — | Used to push branches and open PRs via the GitHub API |
| `CHOMPER_ALLOWED_EMAILS` | — | Comma-separated emails allowed to trigger the agent via `@chomper` comments. **If unset or empty, any OpenProject user can trigger the agent;** set it to gate triggers to specific people. |

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

**`.env`**

Written by the first-run setup wizard (chmod 600, gitignored).

```bash
OPENPROJECT_URL=https://community.openproject.org
OPENPROJECT_TOKEN=your_readonly_token
OP_REPO_PATH=../openproject   # or "false" to have chomper clone automatically
GITHUB_TOKEN=ghp_...
```

**`items/<id>/item.json` schema** (full WP metadata, written at poll time)

```json
{
  "id":          "42",
  "subject":     "Null check in UserService",
  "url":         "https://community.openproject.org/work_packages/42",
  "status":      "New",
  "priority":    "Normal",
  "assignee":    "unassigned",
  "responsible": "unassigned",
  "author":      "Jane Smith",
  "version":     "14.0",
  "category":    "auth",
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

### Architecture & Refactoring
* Explore alternatives to Claude Code. This has multiple reasons, and one of them is the [hostility towards non-interactive users](https://www.reddit.com/r/ClaudeCode/comments/1tccd7c/its_official_anthropic_pulled_the_plug_on_all/).
  * The infra is ready for this, we can just replace the chomper-claude container with some other thing that listens on HTTP :3000
* Use separate agents for development and review to clearly split domain ownership

### Features
* Make the agent mode leverage dedicated sub-WPs or categories/labels instead of brute-force polling
* Correctly set the target branch for release-specific fixes
  * rough idea: If the WP Version field is set to {ver} AND `origin/release/{ver}[\.0-9]*` exists AND we're past the release freeze day, base the PR on the release branch
  * Or, just set it manually for now. Or, explicitly prompt for it.

### Fixes & Hardening
* Switch to Anthropic API tokens + simple auth token replacement proxy for better isolation
  * This setup will make it harder for anyone to extradite the Anthropic auth token, since the container won't have access to it 
  * One disadvantage: API tokens are billed separately. However, after 6th of June, we'll have to pay anyway.
* Re-enable test runs as part of the fix gate once runner container has access to the OpenProject test suite
* Limit egress from the Claude container to only Anthropic & Rails guides
* Add more robust error handling around the HTTP interface between runner and claude containers (timeouts, retries, malformed responses, etc.)
