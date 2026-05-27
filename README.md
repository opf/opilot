## [Internal Experimental PoC! Please do not share with anyone.]

# openproject-chomper

Automated bug-fixing loop for OpenProject backlogs. Fetches open bugs, triages them by complexity, then has Claude plan, write tests, implement fixes, and commit — all inside a Docker container. You review and push when you're happy.

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
- [Reference](#reference)
- [TODO](#todo)

---

## Requirements

- **Docker** (used to run Claude Code in an isolated container)
- `jq` and `curl` on the host
- `gh` CLI for publishing plans as gists and opening PRs 
- A checked-out `openproject` repo somewhere on disk
- An OpenProject API token (preferably scoped only to reading your target WPs)

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
  ┌─ HOST ─────────────────────────────────────────────────────────────────-─┐
  │                                                                          │
  │   ./chomper fix                                                          │
  │        │                                                                 │
  │        │ # Stage 1: Pull WP data                                         │
  │        │                           ┌─────────────────────────────────┐   │
  │        │  curl ───────────────────►│  OpenProject API                │   │
  │        │                           │  GET /api/v3/projects/:id/      │   │ 
  │        │  ◄── work packages ───────│       work_packages             │   │
  │        │  ◄── activities ──────────│  GET /api/v3/work_packages/:id/ │   │
  │        │  ◄── emoji reactions ─────│       activities                │   │
  │        │                           └─────────────────────────────────┘   │
  │        │                                                                 │
  │        │  ...writes data into .chomper/...                               │
  │        │                                                                 │
  │        │ # Stage 2 & 3: Triage + Fix using Claude                        │
  │        │                                                                 │  
  │        │  git worktree add --detach .chomper/worktree                    │
  │        │  docker exec -i $CLAUDE_CONTAINER" claude                       │
  │        │                                                                 │    
  │        │              ┌─ Docker container ───────────────────┐           │
  │        │   prompt     │                                      │           │
  │        │  ───────────►│  claude -p                           │           │
  │        │              │                                      │           │
  │        │  ◄───────────│                                      │           │
  │        │   streamed   │  volumes:                            │           │
  │        │   JSON       │   .chomper/worktree → /repo   (rw)   │           │
  │        │              │   .chomper/         → /state  (rw)   │           │
  │        │              │   claude-auth/      → /root/.claude  │           │
  │        │              └──────────────────────────────────────┘           │
  │        └─────────────────────────────────────────────────────────────────│
  │                                                                          │
  │  ./chomper publish                                                       │
  │        │                                                                 │
  │        │  # Stage 4: Publish                                             │
  │        │                                                                 │
  │        │                     ┌─────────────────────────────────┐         │
  │        ├── gist create ─────►│  GitHub                         │         │
  │        └── pr create ───────►│  secret gist  → plan URL        │         │
  │                              │  draft PR     → pr_url.txt      │         │
  │                              └─────────────────────────────────┘         │
  └──────────────────────────────────────────────────────────────────────────┘
```
---

## Commands

| Invocation | Behaviour |
|---|---|
| `./chomper fix` | Pull → triage → fix all pending issues |
| `./chomper fix 123 456` | Load only those WP IDs and fix them (skips pull + triage) |
| `./chomper plan` | Pull + triage + generate plans only, no implementation |
| `./chomper plan 123` | Generate a plan for one specific issue |
| `./chomper publish` | Push all committed fix branches and open draft PRs |
| `./chomper publish 123` | Push and open PR for one specific issue |
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

**Retry a blocked item:** set `passes` back to `false` in `.chomper/backlog.json` and re-run.

---

## Repo layout

**What you clone:**

```
openproject-chomper/
├── chomper         ← entry point
├── lib/
│   ├── helpers.sh  ← claude wrappers, test runners, utilities
│   ├── pull.sh     ← fetch from OpenProject
│   ├── triage.sh   ← AI triage stage
│   ├── fix.sh      ← plan → test → impl → commit
│   ├── publish.sh  ← push branches, open PRs
│   └── ui.sh       ← status, setup, docker, usage
├── Dockerfile      ← Claude Code container image
└── README.md
```

**Runtime state (gitignored, created on first run):**

```
.chomper/
├── config           ← credentials & settings (chmod 600)
├── backlog.json     ← source of truth: API data + triage + fix state
├── progress.txt     ← session log
├── chomp.log        ← full prompt + response log
├── claude-auth/     ← persisted Claude container auth
├── worktree/        ← isolated git worktree (your repo checkout is untouched)
└── items/
    └── <id>/
        ├── item.json    ← issue snapshot
        ├── plan.md      ← Writer's implementation plan
        ├── review.txt   ← Reviewer's critique (deleted after merge)
        ├── pr.md        ← generated PR description
        ├── gist.txt     ← plan gist URL
        └── pr_url.txt   ← PR URL (written by publish)
```

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_IMAGE` | `chomper-claude` | Docker image name (rebuilt automatically if missing) |
| `ANTHROPIC_API_KEY` | — | Passed into the container if set; otherwise Claude uses its stored auth |

---

## Reference

**`.chomper/config`**
If these are not specified, the scripts asks for them interactively at the beginning of the run.

```bash
OP_URL="https://community.openproject.org"
TOKEN="your_readonly_token"
PROJECT_ID="your-project-slug"
REPO_PATH="../openproject"
```

**`backlog.json` item schema**

```json
{
  "id":             "42",
  "subject":        "Null check in UserService",
  "url":            "https://community.openproject.org/work_packages/42",
  "status":         "New",
  "priority":       "Normal",
  "assignee":       "unassigned",
  "author":         "Jane Smith",
  "version":        "14.0",
  "category":       "auth",
  "created_at":     "2024-01-15T10:00:00Z",
  "updated_at":     "2024-01-20T14:30:00Z",
  "description":    "Raw description text...",
  "comments": [
    {"user": "John Doe", "created_at": "2024-01-16T09:00:00Z", "text": "I can reproduce this..."}
  ],
  "locality_group": "auth",
  "complexity":     "trivial",
  "files_touched":  ["src/services/UserService.ts"],
  "ai_category":    "null-safety",
  "passes":         false
}
```

`passes` values: `null` → untriaged · `false` → pending · `true` → committed · `"blocked"` → failed after 3 attempts

## TODO

### Architecture & Refactoring
* Rewrite to Ruby!
  * Make sure the LLM integration is treated as a _swappable adapter_. We are likely to move away from Claude. This has multiple reasons, and one of them is the [hostility towards non-interactive users](https://www.reddit.com/r/ClaudeCode/comments/1tccd7c/its_official_anthropic_pulled_the_plug_on_all/).
* Keep `backlog.json` compact (ID + subject + URL + scoring) and store the other WP data in its item folder
* Replace the clumsy `passes` field with some proper status indicator

### Features
* Introduce a background mode: Script continually polls for new interactions on the OP instance and then picks up new work to chomp through.
  * The interactions can have multiple forms. Here are the ideas so far, in order of descending preference:
    * Creating a dedicate sub-WP (type "AI Workflow")
    * Tagging the WP with a relevant Category (or even Label, once we port them over from JIRA)
    * Tagging the AI workflow user in Activity
* Manual plan approvals for script mode
* Manual plan approvals for background mode
* Skip extensive planning for very simple tickets.
* Correctly set the target branch for release-specific fixes
  * Might not be trivial to determine this automatically -- solve this with a prompt for now

### Fixes & Hardening
* Do not allow empty OP token
* Fix PR title: shorter and with ID in bracket at the beginning
* Fix inconsistent handling of chomping queues
  * Right now, items are usually appended, but when the script is ran in single-WP mode, the queue gets wiped out
  * Make sure items are always appended and add the possibility to purge them from the queue
