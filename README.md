## [Internal Experimental PoC! Please do not share with anyone.]

# openproject-chomper

Automated bug-fixing loop for OpenProject backlogs. Fetches open bugs, triages them by complexity, then has Claude plan, write tests, implement fixes, and commit — all inside a Docker container. You review and push when you're happy.

```
git clone → ./chomper fix → answer a few questions → have a coffee and wait for PRs
```

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

## Three automatic stages

Every `./chomper fix` run checks three conditions in order:

| Stage | Condition | What runs |
|---|---|---|
| **1 · Pull** | Always on a full run | Interactive filter prompt (project, type, status, version), then fetches matching work packages from the OpenProject API, paginated. Merges into existing backlog — triage and fix progress is preserved. |
| **2 · Triage** | Any item has `passes == null` | Claude reads each issue and assigns `locality_group`, `complexity`, `files_touched`, `ai_category`; backlog sorted trivial→complex |
| **3 · Fix** | Always | Works through pending issues in order |

When specific IDs are passed (`./chomper fix 123 456`), stages 1 and 2 are skipped — the named issues are loaded directly and fixed immediately.

---

## The fix loop

Issues already assigned to a developer are skipped automatically.

Each issue follows this pipeline, fully automated:

| Step | What happens |
|---|---|
| **Writer** | Claude reads the issue JSON and source files, produces a plan (`items/<id>/plan.md`), published as a secret GitHub gist |
| **Reviewer** | A second Claude call critiques the plan — wrong paths, missing edge cases, blast radius. Verdicts: `PROCEED` / `REVISE` / `REJECT` |
| **REVISE** | Claude rewrites the plan incorporating the review, then proceeds |
| **REJECT** | Branch is deleted, item logged as `REJECTED`, loop moves to next issue |
| **Failing tests** | For `moderate` and `complex` issues only: Claude writes tests that must fail before any implementation exists (RSpec for Ruby, Vitest for TypeScript) |
| **Implement** | Claude implements the fix according to the approved plan |
| **Test gate** | Script runs tests directly via `bin/compose`; up to 3 attempts. Between failures Claude reads the output and tries again |
| **Auto-commit** | On green: `git commit -m "fix(<group>): <title> (WP #<id>)"` + PR description written to `items/<id>/pr.md` |
| **Blocked** | After 3 failed attempts the branch is deleted and the item marked `"blocked"` |

In `plan` mode (`./chomper plan`), the pipeline stops after the reviewer approves the plan — no tests, no implementation.

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

**`progress.txt`**

```
2026-05-24T10:12|42|fix/42-null-check-userservice|committed
2026-05-24T10:31|9|fix/9-type-mismatch-api|BLOCKED
2026-05-24T10:45|17|-|REJECTED
2026-05-24T11:00|42|fix/42-null-check-userservice|published
```

---

## API token scoping

Create a dedicated token in OpenProject under *My Account → Access Tokens*. It needs exactly one permission: **View work packages** on the target project. No write access, no admin, no other projects. The token is stored locally in `.chomper/config` and is never committed.
