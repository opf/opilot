## [Internal Experimental PoC! Please do not share with anyone.]

# openproject-chomper

Automated bug-fixing loop for OpenProject backlogs. Fetches open bugs, triages them by complexity, then has Claude plan, implement fixes, and commit — all inside a Docker container. You review and push when you're happy.

```
git clone → ./chomper fix → answer a few questions → have a coffee and wait for PRs
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
- A GitHub token with repo + gist write access (for publishing PRs and plan gists)
- An OpenProject API token (preferably scoped only to reading your target WPs)
- Optionally, a local `openproject` repo — chomper can clone one automatically if you don't have it

---

## Quick start

```bash
git clone https://github.com/opf/openproject-chomper
cd openproject-chomper
# Pull packages, generate plans, prepare commits
./chomper fix
# See what progress has been made
./chomper status
# Publish draft GitHub PRs
./chomper publish
```

## Bird's-eye view

```
  ┌─ HOST ───────────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │   ./chomper fix  (bash wrapper)                                              │
  │        │                                                                     │
  │        │  reads .env (writes on first run), ensures openproject exists        │
  │        │  docker compose run --rm runner ruby bin/chomper fix                │
  │        │                                                                     │
  │        │         ┌─ runner container (Ruby 4.0) ──────────────────────┐      │
  │        │         │                                                    │      │
  │        │         │  Stage 1: Pull                                     │      │
  │        │         │    HTTP → OpenProject API (work packages,          │      │
  │        │         │            activities, reactions)                  │      │
  │        │         │    writes .chomper/backlog.json                    │      │
  │        │         │    writes .chomper/items/<id>/item.json            │      │
  │        │         │                                                    │      │
  │        │         │  Stage 2: Triage / Stage 3: Fix                    │      │
  │        │         │    HTTP POST http://claude:3000  ◄─────────────────┼───┐  │
  │        │         │                                                    │   │  │
  │        │         │                                                    │   │  │
  │        │         └────────────────────────────────────────────────────┘   │  │
  │        │                                                                  │  │
  │        │         ┌─ claude container (Node.js + Claude Code) ──────────┐  │  │
  │        │         │  server.js  listens on :3000                 ◄──────┼──┘  │
  │        │         │  POST /  →  claude -p --output-format stream-json   │     │
  │        │         │                                                     │     │
  │        │         │  volumes:                                           │     │
  │        │         │    .chomper/openproject → /repo   (rw)              │     │
  │        │         │    .chomper/         → /state  (rw)                 │     │
  │        │         │    claude-auth/      → /root/.claude                │     │
  │        │         └─────────────────────────────────────────────────────┘     │
  │                                                                              │
  │   ./chomper publish                                                          │
  │        │                                                                     │
  │        │  Stage 4: Publish                                                   │
  │        │                     ┌─────────────────────────────────┐             │
  │        ├── gist create ─────►│  GitHub                         │             │
  │        └── pr create ───────►│  public gist  → plan URL        │             │
  │                              │  draft PR     → pr_url.txt      │             │
  │                              └─────────────────────────────────┘             │
  └──────────────────────────────────────────────────────────────────────────────┘
```

---

## Commands

| Invocation | Behaviour |
|---|---|
| `./chomper fix` | Pull → triage → show plan → prompt for approval → fix all pending issues |
| `./chomper fix 123 456` | Load only those WP IDs, show plan, prompt for approval, fix them (skips pull + triage) |
| `./chomper plan` | Pull + triage + generate plans only, no implementation |
| `./chomper plan 123` | Generate a plan for one specific issue |
| `./chomper publish` | Push all committed fix branches and open draft PRs |
| `./chomper publish 123` | Push and open PR for one specific issue |
| `./chomper purge <id ...>` | Remove specific items from the queue |
| `./chomper status` | Show per-issue status with OpenProject URL, plan gist, and PR link |
| `./chomper reset` | De-register the worktree and delete `.chomper/` (fresh start) |
| `./chomper --help` | Show usage |

---

## Reviewing & pushing

All commits are local until you push. Use the `publish` command to push branches and open draft PRs in one step:

```bash
./chomper publish        # push all committed fixes
./chomper publish 123    # push one specific fix
```

`publish` is idempotent — if a PR already exists for a branch it records the URL and moves on.

`./chomper status` shows each issue with its OpenProject link, plan gist URL, and PR link so you can track what's been published at a glance.

**Retry a blocked item:** set `state` back to `"pending"` in `.chomper/backlog.json` and re-run.

---

## Repo layout

**What you clone:**

```
openproject-chomper/
├── chomper                  ← bash entry point (sets up Docker, runs runner)
├── bin/chomper              ← Ruby CLI (runs inside the runner container)
├── lib/chomper/
│   ├── cli.rb              ← command dispatch
│   ├── context.rb          ← shared config and paths
│   ├── backlog.rb          ← backlog.json read/write
│   ├── http.rb             ← thin HTTP wrapper
│   ├── helpers.rb          ← shared utilities (branch_slug, strip_ansi, …)
│   ├── pull.rb             ← fetch from OpenProject API
│   ├── triage.rb           ← AI triage stage
│   ├── fix.rb              ← plan → impl → commit
│   ├── publish.rb          ← push branches, open PRs
│   ├── claude.rb           ← HTTP client for the Claude container
│   └── ui.rb               ← status display, usage, reset
├── test/
│   ├── test_helper.rb
│   └── chomper/
│       ├── backlog_test.rb
│       ├── context_test.rb
│       ├── fix_test.rb
│       ├── helpers_test.rb
│       ├── http_test.rb
│       ├── pull_test.rb
│       └── triage_test.rb
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
├── backlog.json     ← lightweight index: id, subject, url, state, scoring fields
├── progress.txt     ← session log
├── chomp.log        ← full prompt + response log
├── claude-auth/     ← persisted Claude container auth
├── openproject/     ← git worktree or fresh clone of openproject
└── items/
    └── <id>/
        ├── item.json    ← full WP metadata (written at pull time)
        ├── plan.md      ← Writer's implementation plan
        ├── review.txt   ← Reviewer's critique (deleted after plan review)
        ├── pr.md        ← generated PR description
        ├── gist.txt     ← plan gist URL
        └── pr_url.txt   ← PR URL (written by publish)
```

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Passed into the Claude container; falls back to stored auth if unset |
| `GITHUB_TOKEN` | — | Used by publish to create gists and open PRs via the GitHub API |
| `CHOMPER_ALLOWED_EMAILS` | — | Comma-separated list of emails authorised to trigger the agent via `@chomper` comments. If unset or empty, **all triggers are denied**. |

---

## Development

The test suite runs inside the runner container so the Ruby version and gem environment match production exactly.

**Run all tests:**

```bash
docker compose run --no-deps --rm runner bundle exec rake
```

**Run a single file:**

```bash
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/chomper/backlog_test.rb
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
OP_URL=https://community.openproject.org
TOKEN=your_readonly_token
OP_REPO_PATH=../openproject   # or "false" to have chomper clone automatically
GITHUB_TOKEN=ghp_...
```

**`backlog.json` item schema** (pointers + scoring only)

```json
{
  "id":             "42",
  "subject":        "Null check in UserService",
  "url":            "https://community.openproject.org/work_packages/42",
  "state":          "pending",
  "locality_group": "auth",
  "complexity":     "trivial",
  "files_touched":  ["src/services/UserService.ts"],
  "ai_category":    "null-safety"
}
```

`state` values: `untriaged` · `requested` · `refinement_requested` · `fix_approved` · `pending` · `planned` · `in_progress` · `committed` · `blocked`

**`items/<id>/item.json` schema** (full WP metadata, written at pull time)

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
* Introduce a background mode: Script continually polls for new interactions on the OP instance and then picks up new work to chomp through.
  * The interactions can have multiple forms. Here are the ideas so far, in order of descending preference:
    * Creating a dedicate sub-WP (type "AI Workflow")
    * Tagging the WP with a relevant Category (or even Label, once we port them over from JIRA)
    * Tagging the AI workflow user in Activity
* Manual plan approvals for background mode
* Skip extensive planning for very simple tickets.
* Correctly set the target branch for release-specific fixes
  * rough idea: If the WP Version field is set to {ver} AND `origin/release/{ver}[\.0-9]*` exists AND we're past the release freeze day, base the PR on the release branch
  * Or, just set it manually for now. Or, explicitly prompt for it.

### Fixes & Hardening
* Re-enable test runs as part of the fix gate once runner container has access to the OpenProject test suite
